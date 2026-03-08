defmodule HttpDouble.MockRule do
  @moduledoc """
  Representation of a mock or expectation rule for HTTP requests.

  Rules are evaluated by `HttpDouble.MockEngine` and can match on method, path,
  host, query, headers, body, connection id and call index, or use arbitrary
  predicate functions.
  """

  alias HttpDouble.Request

  @typedoc "Rule kind."
  @type kind :: :stub | :expect

  @typedoc "Metadata provided to predicate functions and callbacks."
  @type meta :: %{
          conn_id: non_neg_integer(),
          call_index: non_neg_integer()
        }

  @enforce_keys [:id, :kind, :matcher, :respond]
  defstruct id: nil,
            kind: :stub,
            matcher: :any,
            respond: nil,
            conn_ids: nil,
            call_range: nil,
            max_calls: :infinity,
            times_used: 0

  @typedoc "Internal struct type."
  @type t :: %__MODULE__{
          id: reference(),
          kind: kind(),
          matcher: term(),
          respond: HttpDouble.response_spec(),
          conn_ids: [non_neg_integer()] | nil,
          call_range: Range.t() | nil,
          max_calls: :infinity | non_neg_integer(),
          times_used: non_neg_integer()
        }

  @doc """
  Builds a rule from a keyword options list.

  Supported options:

    * `:matcher` – see `t:HttpDouble.matcher/0`
    * `:respond` – response specification
    * `:conn_id` / `:conn_ids` – restrict to specific connection(s)
    * `:call_range` – restrict to a specific range of call indices
    * `:max_calls` – maximum number of times the rule may match
  """
  @spec build(kind(), Keyword.t()) :: t()
  def build(kind, opts) when kind in [:stub, :expect] do
    matcher = Keyword.get(opts, :matcher, :any)
    respond = Keyword.fetch!(opts, :respond)

    conn_ids =
      case {Keyword.get(opts, :conn_id), Keyword.get(opts, :conn_ids)} do
        {nil, nil} -> nil
        {id, nil} when is_integer(id) -> [id]
        {nil, ids} when is_list(ids) -> ids
        {_id, ids} when is_list(ids) -> ids
      end

    call_range = Keyword.get(opts, :call_range)
    max_calls = Keyword.get(opts, :max_calls, :infinity)

    %__MODULE__{
      id: make_ref(),
      kind: kind,
      matcher: matcher,
      respond: respond,
      conn_ids: conn_ids,
      call_range: call_range,
      max_calls: max_calls,
      times_used: 0
    }
  end

  @doc """
  Produces metadata from a request and optional call index.
  """
  @spec meta_from_request(Request.t(), non_neg_integer() | nil) :: meta()
  def meta_from_request(%Request{conn_id: conn_id, request_index: idx}, nil) do
    %{conn_id: conn_id || 0, call_index: idx}
  end

  def meta_from_request(%Request{conn_id: conn_id}, call_index) do
    %{conn_id: conn_id || 0, call_index: call_index || 0}
  end
end
