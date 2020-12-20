defmodule Fika.Compiler.CodeServer.FunctionDependencies do
  @moduledoc """
  Handles function dependencies given a `t :digraph.digraph`.

  Helper module that is used by the TypeChecker and the CodeServer.
  """

  def set_function_dependency(graph, source, target) do
    graph
    |> add_vertex(source)
    |> add_vertex(target)
    |> add_edge(source, target)

    if :digraph.get_cycle(graph, source) do
      {:error, :cycle_encountered}
    else
      :ok
    end
  end

  defp add_vertex(graph, v) do
    :digraph.add_vertex(graph, v, v)
    graph
  end

  defp add_edge(graph, source, target) do
    edge = {source, target}

    :digraph.add_edge(graph, edge, source, target, edge)
    graph
  end
end