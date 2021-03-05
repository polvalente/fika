defmodule Fika.Compiler.TypeChecker.ParallelTypeChecker do
  use GenServer

  require Logger

  alias Fika.Compiler.{
    TypeChecker,
    TypeChecker.FunctionMatch,
    CodeServer
  }

  alias Fika.Compiler.TypeChecker.Types, as: T

  # Returns :ok | :error
  def check(module_name, ast) do
    start_link(module_name, ast)

    receive do
      {:result, result} ->
        Logger.debug("ParallelTypeChecker for #{module_name} returned #{inspect(result)}")
        result
    end
  end

  def start_link(module_name, ast) do
    pid = self()
    signature_map = signature_map(ast)
    GenServer.start_link(__MODULE__, [pid, module_name, signature_map, ast])
  end

  def get_result(pid, signature) do
    GenServer.call(pid, {:get_result, signature})
  end

  def post_result(pid, signature, result) do
    GenServer.cast(pid, {:post_result, signature, result})
  end

  def init([caller_pid, module_name, signature_map, ast]) do
    state = %{
      caller_pid: caller_pid,
      module_name: module_name,
      local_functions: signature_map,
      unchecked_functions: signature_map,
      checked_functions: %{},
      waiting: %{},
      error_found: false,
      ast: ast
    }

    Logger.debug("Initializing ParallelTypeChecker for #{module_name}")

    {:ok, state, {:continue, :start}}
  end

  def handle_continue(:start, state) do
    pid = self()

    Enum.each(state.unchecked_functions, fn {signature, function} ->
      # We need to use this approach instead of Task.async_stream due to
      # timeout and concurrency issues
      Task.start_link(fn ->
        result =
          function
          |> TypeChecker.check(%{
            ast: state.ast,
            module_name: state.module_name,
            current_signature: signature,
            type_checker_pid: pid
          })

        __MODULE__.post_result(pid, signature, result)
      end)
    end)

    {:noreply, state}
  end

  def handle_call({:get_result, signature}, from, state) do
    if {s, _, vars} = FunctionMatch.find_by_call(state.local_functions, signature) do
      if result = Map.get(state.checked_functions, s) do
        result = FunctionMatch.replace_vars(result, vars)
        {:reply, result, state}
      else
        state =
          update_in(state, [:waiting, s], fn
            nil -> [from]
            list -> [from | list]
          end)

        {:noreply, state}
      end
    else
      result = {:error, "Function #{signature} not found in #{state.module_name}"}
      {:reply, result, state}
    end
  end

  def handle_cast({:post_result, signature, result}, state) do
    Logger.debug("Result of type checking #{signature} = #{inspect(result)}")

    state =
      state
      |> notify_waiting_type_checks(signature, result)
      |> mark_function(signature, result)
      |> process_error(result)
      |> maybe_finish()

    # TODO: when we have private functions, do this conditionally.
    CodeServer.set_type(signature, result)

    {:noreply, state}
  end

  def handle_info(:finish, state) do
    result =
      if state.error_found do
        :error
      else
        :ok
      end

    send(state.caller_pid, {:result, result})

    Logger.debug(
      "Stopping ParallelTypeChecker for #{state.module_name} with result #{inspect(result)}"
    )

    {:stop, :normal, state}
  end

  defp notify_waiting_type_checks(state, signature, result) do
    {waitlist, waiting} = Map.pop(state.waiting, signature)

    if waitlist do
      Enum.each(waitlist, fn from ->
        GenServer.reply(from, result)
      end)
    end

    Map.put(state, :waiting, waiting)
  end

  defp mark_function(state, signature, {:ok, %T.Loop{type: result}}) do
    %{
      state
      | unchecked_functions: Map.delete(state.unchecked_functions, signature),
        checked_functions: Map.put(state.checked_functions, signature, result)
    }
  end

  defp mark_function(state, signature, result) do
    %{
      state
      | unchecked_functions: Map.delete(state.unchecked_functions, signature),
        checked_functions: Map.put(state.checked_functions, signature, result)
    }
  end

  defp process_error(state, result) do
    case result do
      {:error, _} ->
        # TODO
        # Compiler.log(:error, result)
        Map.put(state, :error_found, true)

      _ ->
        state
    end
  end

  defp maybe_finish(state) do
    if map_size(state.unchecked_functions) == 0 do
      Logger.debug("No more unchecked_functions in #{state.module_name}.")
      send(self(), :finish)
    end

    state
  end

  defp signature_map(module, function_asts) do
    Enum.map(function_asts, fn function ->
      signature = TypeChecker.function_ast_signature(module, function)
      {signature, function}
    end)
    |> Map.new()
  end
end
