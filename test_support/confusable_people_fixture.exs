defmodule Jido.SimpleMem.TestSupport.ConfusablePeopleFixture do
  @moduledoc false

  @dataset [
    %{
      class: :semantic,
      kind: :profile,
      text:
        "Alice Johnson lives in Portland, works on platform reliability, and prefers espresso after lunch",
      persons: ["Alice Johnson"],
      topic: "profile",
      tags: ["team:platform", "city:portland"]
    },
    %{
      class: :semantic,
      kind: :profile,
      text:
        "Alice Smith lives in Austin, works on growth analytics, and prefers green tea in the morning",
      persons: ["Alice Smith"],
      topic: "profile",
      tags: ["team:growth", "city:austin"]
    },
    %{
      class: :semantic,
      kind: :profile,
      text:
        "Alicia Stone lives in Portland, works on design systems, and prefers pour-over coffee during reviews",
      persons: ["Alicia Stone"],
      topic: "profile",
      tags: ["team:design", "city:portland"]
    },
    %{
      class: :semantic,
      kind: :profile,
      text:
        "Morgan Lee lives in Denver, supports the billing service, and prefers coffee before standup",
      persons: ["Morgan Lee"],
      topic: "profile",
      tags: ["team:billing", "city:denver"]
    },
    %{
      class: :semantic,
      kind: :profile,
      text:
        "Morgan Reed lives in Seattle, owns roadmap reviews, and prefers tea during planning sessions",
      persons: ["Morgan Reed"],
      topic: "profile",
      tags: ["team:product", "city:seattle"]
    },
    %{
      class: :semantic,
      kind: :profile,
      text:
        "Jordan Kim lives in Toronto, maintains the developer portal, and prefers chai while writing docs",
      persons: ["Jordan Kim"],
      topic: "profile",
      tags: ["team:developer-experience", "city:toronto"]
    }
  ]

  @query_expectations [
    {"Where does Alice Smith live?", "Alice Smith", "Austin"},
    {"What does Alice Johnson prefer?", "Alice Johnson", "espresso"},
    {"Who supports the billing service?", "Morgan Lee", "billing service"},
    {"What does Morgan Reed prefer?", "Morgan Reed", "tea"},
    {"Where does Jordan Kim live?", "Jordan Kim", "Toronto"}
  ]

  @spec dataset() :: [map()]
  def dataset, do: @dataset

  @spec query_expectations() :: [{String.t(), String.t(), String.t()}]
  def query_expectations, do: @query_expectations
end
