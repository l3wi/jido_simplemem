defmodule Jido.SimpleMem.ApiBreakingChangeTest do
  use ExUnit.Case, async: true

  test "compatibility facade methods were removed" do
    assert Code.ensure_loaded(Jido.SimpleMem)

    refute function_exported?(Jido.SimpleMem, :remember, 3)
    refute function_exported?(Jido.SimpleMem, :retrieve, 3)
    refute function_exported?(Jido.SimpleMem, :answer, 3)
    refute function_exported?(Jido.SimpleMem, :forget, 3)

    assert function_exported?(Jido.SimpleMem, :add_dialogue, 4)
    assert function_exported?(Jido.SimpleMem, :add_dialogues, 3)
    assert function_exported?(Jido.SimpleMem, :finalize, 2)
    assert function_exported?(Jido.SimpleMem, :ask, 3)
    assert function_exported?(Jido.SimpleMem, :get_all_memories, 2)
    assert function_exported?(Jido.SimpleMem, :delete_memory, 3)
    assert function_exported?(Jido.SimpleMem, :explain, 3)
  end
end
