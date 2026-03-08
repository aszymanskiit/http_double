defmodule HttpDouble.MockEngine do
  @moduledoc """
  Evaluation engine for mock and expectation rules.

  It is responsible for:

    * matching incoming HTTP requests against configured rules
    * supporting sequence responses (lists) and callback functions
    * tracking usage counts for expectations
    * returning a concrete response specification for the connection layer
  """

  alias HttpDouble.{MockRule, Request}

  @typedoc "Result of rule evaluation."
  @type result :: %{
          response: term(),
          rule_id: reference() | nil,
          rules: [MockRule.t()]
        }

  @doc """
  Applies mock/expectation rules according to the given mode.

  Modes:

    * `:mock_first` – try rules, fall back to `fallback.()` when no match
    * `:mock_only` – try rules, return `{:no_route, default}` when no match
    * `:routes_only` – ignore rules, always call `fallback.()`
  """
  @spec apply(
          [MockRule.t()],
          Request.t(),
          non_neg_integer(),
          :mock_first | :mock_only | :routes_only,
          (-> {term(), reference() | nil} | {:no_route, term()})
        ) :: result()
  def apply(rules, _request, _conn_id, :routes_only, fallback) do
    %{
      response: fallback.(),
      rule_id: nil,
      rules: rules
    }
  end

  def apply(rules, request, conn_id, mode, fallback) when mode in [:mock_first, :mock_only] do
    case find_and_realise_rule(rules, request, conn_id) do
      {:ok, response, new_rules, rule_id} ->
        %{response: response, rule_id: rule_id, rules: new_rules}

      :nomatch ->
        default =
          case mode do
            :mock_first -> fallback.()
            :mock_only -> {:no_route, %{status: 404, body: "Not found"}}
          end

        %{response: default, rule_id: nil, rules: rules}
    end
  end

  @spec find_and_realise_rule([MockRule.t()], Request.t(), non_neg_integer()) ::
          {:ok, term(), [MockRule.t()], reference()} | :nomatch
  defp find_and_realise_rule(rules, request, conn_id) do
    do_find(rules, request, conn_id, [], 0)
  end

  defp do_find([], _request, _conn_id, _acc, _idx), do: :nomatch

  defp do_find([rule | rest], request, conn_id, acc, idx) do
    call_index = idx + 1

    if matches?(rule, request, conn_id, call_index) and under_call_limit?(rule) do
      {response, updated_rule} = realise(rule, request, call_index)
      new_rules = Enum.reverse(acc, [updated_rule | rest])
      {:ok, response, new_rules, rule.id}
    else
      do_find(rest, request, conn_id, [rule | acc], call_index)
    end
  end

  @spec matches?(MockRule.t(), Request.t(), non_neg_integer(), non_neg_integer()) :: boolean()
  defp matches?(
         %MockRule{conn_ids: nil, matcher: matcher, call_range: range},
         request,
         _conn_id,
         idx
       ) do
    call_index_ok?(range, idx) and match_matcher(matcher, request, idx)
  end

  defp matches?(
         %MockRule{conn_ids: conn_ids, matcher: matcher, call_range: range},
         request,
         conn_id,
         idx
       ) do
    conn_id in conn_ids and call_index_ok?(range, idx) and match_matcher(matcher, request, idx)
  end

  defp call_index_ok?(nil, _idx), do: true
  defp call_index_ok?(%Range{} = range, idx), do: idx in range

  defp match_matcher(:any, _request, _idx), do: true

  defp match_matcher({:method, method}, %Request{method: req_method}, _idx) do
    normalise_method(method) == normalise_method(req_method)
  end

  defp match_matcher({:path, path}, %Request{path: req_path}, _idx) do
    path == req_path
  end

  defp match_matcher({:prefix, prefix}, %Request{path: req_path}, _idx) do
    String.starts_with?(req_path, prefix)
  end

  defp match_matcher({:path_regex, %Regex{} = re}, %Request{path: req_path}, _idx) do
    Regex.match?(re, req_path)
  end

  defp match_matcher({:route, method, path}, %Request{method: req_method, path: req_path}, _idx) do
    normalise_method(method) == normalise_method(req_method) and path == req_path
  end

  defp match_matcher({:fn, fun}, %Request{} = request, idx) when is_function(fun, 2) do
    meta = MockRule.meta_from_request(request, idx)
    safe_bool(fun.(request, meta))
  end

  defp match_matcher({:fn, fun}, %Request{} = request, _idx) when is_function(fun, 1) do
    safe_bool(fun.(request))
  end

  defp match_matcher(%{} = map, %Request{} = request, idx) do
    match_by_map(map, request, idx)
  end

  defp match_matcher(_other, _request, _idx), do: false

  defp normalise_method(method) when is_binary(method), do: String.upcase(method)

  defp normalise_method(method) when is_atom(method),
    do: method |> Atom.to_string() |> String.upcase()

  defp safe_bool(val) when val in [true, false], do: val
  defp safe_bool(_), do: false

  defp match_by_map(map, %Request{} = req, idx) do
    Enum.all?(map, fn
      {:method, method} ->
        normalise_method(method) == normalise_method(req.method)

      {:path, path} ->
        path == req.path

      {:path_prefix, prefix} ->
        String.starts_with?(req.path, prefix)

      {:path_regex, %Regex{} = re} ->
        Regex.match?(re, req.path)

      {:host, host} ->
        req.host == host

      {:query, query_map} when is_map(query_map) ->
        Enum.all?(query_map, fn {k, v} ->
          case Map.fetch(req.query, to_string(k)) do
            {:ok, val} -> v in [:any, val]
            :error -> false
          end
        end)

      {:headers, headers} when is_map(headers) ->
        Enum.all?(headers, fn {k, v} ->
          name = String.downcase(to_string(k))

          case Enum.find(req.headers, fn {n, _} -> n == name end) do
            {_, val} ->
              case v do
                :any -> true
                %Regex{} = re -> Regex.match?(re, val)
                other -> val == other
              end

            nil ->
              false
          end
        end)

      {:body, body} when is_binary(body) ->
        req.body == body

      {:body_regex, %Regex{} = re} ->
        Regex.match?(re, req.body)

      {:nth, nth} when is_integer(nth) and nth > 0 ->
        idx == nth

      {:conn_id, conn_id} when is_integer(conn_id) ->
        req.conn_id == conn_id

      {:conn_ids, ids} when is_list(ids) ->
        req.conn_id in ids

      {_other_key, _value} ->
        true
    end)
  end

  @spec under_call_limit?(MockRule.t()) :: boolean()
  defp under_call_limit?(%MockRule{max_calls: :infinity}), do: true

  defp under_call_limit?(%MockRule{max_calls: max, times_used: used}) when is_integer(max),
    do: used < max

  @spec realise(MockRule.t(), Request.t(), non_neg_integer()) :: {term(), MockRule.t()}
  defp realise(%MockRule{} = rule, request, call_index) do
    {response, new_respond} = realise_response(rule.respond, request, call_index)

    updated_rule = %MockRule{
      rule
      | respond: new_respond,
        times_used: rule.times_used + 1
    }

    {response, updated_rule}
  end

  # Sequence responses – use head, keep tail, or repeat last element.
  defp realise_response([single], _request, _idx), do: {single, [single]}

  defp realise_response([head | tail], _request, _idx), do: {head, tail}

  # Callback function (1 or 2 arity); use apply/3 so Dialyzer accepts both arities.
  defp realise_response({:fun, fun}, %Request{} = request, idx) do
    meta = MockRule.meta_from_request(request, idx)

    args =
      case :erlang.fun_info(fun, :arity) do
        {:arity, 2} -> [request, meta]
        _ -> [request]
      end

    result = apply(fun, args)
    {result, {:fun, fun}}
  end

  # Plain response.
  defp realise_response(other, _request, _idx), do: {other, other}
end
