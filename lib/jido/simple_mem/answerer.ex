defmodule Jido.SimpleMem.Answerer do
  @moduledoc false

  @spec answer(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def answer(question, explain, runtime) do
    with {:ok, response} <- runtime.llm_client.answer(question, explain.records, runtime.llm_opts),
         :ok <- validate_response(response) do
      {:ok, response}
    end
  end

  defp validate_response(%{answer: answer}) when is_binary(answer) do
    if String.trim(answer) == "" do
      {:error, {:invalid_answer, :blank_answer}}
    else
      :ok
    end
  end

  defp validate_response(%{"answer" => answer}) when is_binary(answer) do
    if String.trim(answer) == "" do
      {:error, {:invalid_answer, :blank_answer}}
    else
      :ok
    end
  end

  defp validate_response(other), do: {:error, {:invalid_answer, other}}
end
