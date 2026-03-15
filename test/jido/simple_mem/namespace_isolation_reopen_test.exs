defmodule Jido.SimpleMem.NamespaceIsolationReopenTest do
  use ExUnit.Case, async: true

  alias Jido.SimpleMem
  alias Jido.SimpleMem.TestSupport.Factory

  test "multiple namespaces remain isolated across reopen on the same Lance path" do
    path = Factory.unique_path("namespace")

    alpha =
      Factory.target("agent-alpha", path: path, namespace: "user:alpha", session_id: "alpha")

    beta = Factory.target("agent-beta", path: path, namespace: "user:beta", session_id: "beta")

    assert {:ok, _} =
             SimpleMem.add_dialogues(alpha, [
               %{speaker: "user", content: "Sam Carter lives in Lisbon"},
               %{speaker: "user", content: "Sam Carter prefers espresso"}
             ])

    assert {:ok, _} =
             SimpleMem.add_dialogues(beta, [
               %{speaker: "user", content: "Sam Carter lives in Madrid"},
               %{speaker: "user", content: "Sam Carter prefers tea"}
             ])

    reopened_alpha =
      Factory.target("agent-alpha", path: path, namespace: "user:alpha", session_id: "alpha")

    reopened_beta =
      Factory.target("agent-beta", path: path, namespace: "user:beta", session_id: "beta")

    assert {:ok, alpha_answer} = SimpleMem.ask(reopened_alpha, "Where does Sam Carter live?")
    assert alpha_answer.answer =~ "Lisbon"

    assert {:ok, beta_answer} = SimpleMem.ask(reopened_beta, "What does Sam Carter prefer?")
    assert beta_answer.answer =~ "tea"
  end
end
