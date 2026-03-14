defmodule Jido.SimpleMem.PostgresTest do
  use ExUnit.Case, async: false

  alias Jido.SimpleMem.Store.Postgres

  @database_url System.get_env("JIDO_SIMPLEMEM_DATABASE_URL")

  test "postgres adapter provisions schema when configured" do
    if is_nil(@database_url) do
      assert true
    else
      opts = parse_database_url(@database_url)
      assert :ok = Postgres.ensure_ready(opts)
    end
  end

  defp parse_database_url(url) do
    uri = URI.parse(url)
    [username, password] = String.split(uri.userinfo || "postgres:postgres", ":", parts: 2)

    [
      hostname: uri.host,
      port: uri.port || 5432,
      username: username,
      password: password,
      database: String.trim_leading(uri.path || "/postgres", "/"),
      table: "simplemem_units_test"
    ]
  end
end
