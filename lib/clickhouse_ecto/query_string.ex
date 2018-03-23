defmodule ClickhouseEcto.QueryString do

  alias Ecto.Query
  alias Ecto.SubQuery
  alias Ecto.Query.{BooleanExpr, JoinExpr, QueryExpr}
  alias ClickhouseEcto.Connection
  alias ClickhouseEcto.Helpers

  binary_ops =
    [==: " = ", !=: " != ", <=: " <= ", >=: " >= ", <: " < ", >: " > ",
     and: " AND ", or: " OR ", ilike: " ILIKE ", like: " LIKE ", in: " IN ",
     is_nil: " WHERE "]

  @binary_ops Keyword.keys(binary_ops)

  Enum.map(binary_ops, fn {op, str} ->
    def handle_call(unquote(op), 2), do: {:binary_op, unquote(str)}
  end)

  def handle_call(fun, _arity), do: {:fun, Atom.to_string(fun)}

  def select(%Query{select: %{fields: fields}} = query, select_distinct, sources) do
    ["SELECT", select_distinct, ?\s | select_fields(fields, sources, query)]
  end

  def select_fields([], _sources, _query),
    do: "'TRUE'"
  def select_fields(fields, sources, query) do
    Helpers.intersperse_map(fields, ", ", fn
      {key, value} ->
        [expr(value, sources, query), " AS " | Helpers.quote_name(key)]
      value ->
        expr(value, sources, query)
    end)
  end

  def distinct(nil, _, _), do: {[], []}
  def distinct(%QueryExpr{expr: []}, _, _), do: {[], []}
  def distinct(%QueryExpr{expr: true}, _, _), do: {" DISTINCT", []}
  def distinct(%QueryExpr{expr: false}, _, _), do: {[], []}
  def distinct(%QueryExpr{expr: exprs}, sources, query) do
    {[" DISTINCT ON (",
      Helpers.intersperse_map(exprs, ", ", fn {_, expr} -> expr(expr, sources, query) end), ?)],
     exprs}
  end

  def from(%{from: from} = query, sources) do
    {from, name} = Helpers.get_source(query, sources, 0, from)
    [" FROM ", from, " AS " | name]
  end

  def update_fields(%Query{updates: updates} = query, sources) do
    for(%{expr: expr} <- updates,
        {op, kw} <- expr,
        {key, value} <- kw,
        do: update_op(op, key, value, sources, query)) |> Enum.intersperse(", ")
  end

  def update_op(:set, key, value, sources, query) do
    [Helpers.quote_name(key), " = " | expr(value, sources, query)]
  end

  def update_op(:inc, key, value, sources, query) do
    [Helpers.quote_name(key), " = ", Helpers.quote_qualified_name(key, sources, 0), " + " |
     expr(value, sources, query)]
  end

  def update_op(:push, key, value, sources, query) do
    [Helpers.quote_name(key), " = array_append(", Helpers.quote_qualified_name(key, sources, 0),
     ", ", expr(value, sources, query), ?)]
  end

  def update_op(:pull, key, value, sources, query) do
    [Helpers.quote_name(key), " = array_remove(", Helpers.quote_qualified_name(key, sources, 0),
     ", ", expr(value, sources, query), ?)]
  end

  def update_op(command, _key, _value, _sources, query) do
    Helpers.error!(query, "Unknown update operation #{inspect command} for ClickHouse")
  end

  def using_join(%Query{joins: []}, _kind, _prefix, _sources), do: {[], []}
  def using_join(%Query{joins: joins} = query, kind, prefix, sources) do
    froms =
      Helpers.intersperse_map(joins, ", ", fn
        %JoinExpr{qual: :inner, ix: ix, source: source} ->
          {join, name} = Helpers.get_source(query, sources, ix, source)
          [join, " AS " | name]
        %JoinExpr{qual: qual} ->
          Helpers.error!(query, "ClickHouse supports only inner joins on #{kind}, got: `#{qual}`")
      end)

    wheres =
      for %JoinExpr{on: %QueryExpr{expr: value} = expr} <- joins,
          value != true,
          do: expr |> Map.put(:__struct__, BooleanExpr) |> Map.put(:op, :and)

    {[?\s, prefix, ?\s | froms], wheres}
  end

  def join(%Query{joins: []}, _sources), do: []
  def join(%Query{joins: joins} = query, sources) do
    [?\s | Helpers.intersperse_map(joins, ?\s, fn
      %JoinExpr{on: %QueryExpr{expr: expr}, qual: qual, ix: ix, source: source} ->
        {join, name} = Helpers.get_source(query, sources, ix, source)
        [join_qual(qual), join, " AS ", name, " ON " | paren_expr(expr, sources, query)]
    end)]
  end

  def join_qual(:inner), do: "INNER JOIN "
  def join_qual(:inner_lateral), do: "INNER JOIN LATERAL "
  def join_qual(:left),  do: "LEFT OUTER JOIN "
  def join_qual(:left_lateral),  do: "LEFT OUTER JOIN LATERAL "
  def join_qual(:right), do: "RIGHT OUTER JOIN "
  def join_qual(:full),  do: "FULL OUTER JOIN "
  def join_qual(:cross), do: "CROSS JOIN "

  def where(%Query{wheres: wheres} = query, sources) do
    boolean(" WHERE ", wheres, sources, query)
  end

  def having(%Query{havings: havings} = query, sources) do
    boolean(" HAVING ", havings, sources, query)
  end

  def group_by(%Query{group_bys: []}, _sources), do: []
  def group_by(%Query{group_bys: group_bys} = query, sources) do
    [" GROUP BY " |
     Helpers.intersperse_map(group_bys, ", ", fn
       %QueryExpr{expr: expr} ->
         Helpers.intersperse_map(expr, ", ", &expr(&1, sources, query))
     end)]
  end

  def order_by(%Query{order_bys: []}, _distinct, _sources), do: []
  def order_by(%Query{order_bys: order_bys} = query, distinct, sources) do
    order_bys = Enum.flat_map(order_bys, & &1.expr)
    [" ORDER BY " |
     Helpers.intersperse_map(distinct ++ order_bys, ", ", &order_by_expr(&1, sources, query))]
  end

  def order_by_expr({dir, expr}, sources, query) do
    str = expr(expr, sources, query)
    case dir do
      :asc  -> str
      :desc -> [str | " DESC"]
    end
  end

  def limit(%Query{offset: nil, limit: nil}, _sources), do: []
  def limit(%Query{offset: nil, limit: %QueryExpr{expr: expr}} = query, sources) do
    [" LIMIT ", expr(expr, sources, query)]
  end
  def limit(%Query{offset: %QueryExpr{expr: expr_offset}, limit: %QueryExpr{expr: expr_limit}} = query, sources) do
    [" LIMIT ", expr(expr_offset, sources, query), ", ", expr(expr_limit, sources, query)]
  end

  def boolean(_name, [], _sources, _query), do: []
  def boolean(name, [%{expr: expr, op: op} | query_exprs], sources, query) do
    [name |
     Enum.reduce(query_exprs, {op, paren_expr(expr, sources, query)}, fn
       %BooleanExpr{expr: expr, op: op}, {op, acc} ->
         {op, [acc, operator_to_boolean(op), paren_expr(expr, sources, query)]}
       %BooleanExpr{expr: expr, op: op}, {_, acc} ->
         {op, [?(, acc, ?), operator_to_boolean(op), paren_expr(expr, sources, query)]}
     end) |> elem(1)]
  end

  def operator_to_boolean(:and), do: " AND "
  def operator_to_boolean(:or), do: " OR "

  def paren_expr(false, _sources, _query),  do: "(0=1)"
  def paren_expr(true, _sources, _query),   do: "(1=1)"
  def paren_expr(expr, sources, query) do
    [?(, expr(expr, sources, query), ?)]
  end

  def expr({_type, [literal]}, sources, query) do
    expr(literal, sources, query)
  end

  def expr({:^, [], [ix]}, _sources, _query) do
    [?? , Integer.to_string(ix + 1)]
  end

  def expr({{:., _, [{:&, _, [idx]}, field]}, _, []}, sources, _query) when is_atom(field) do
    Helpers.quote_qualified_name(field, sources, idx)
  end

  def expr({:&, _, [idx, fields, _counter]}, sources, query) do
    {_, name, schema} = elem(sources, idx)
    if is_nil(schema) and is_nil(fields) do
      Helpers.error!(query, "ClickHouse requires a schema module when using selector " <>
        "#{inspect name} but none was given. " <>
        "Please specify a schema or specify exactly which fields from " <>
        "#{inspect name} you desire")
    end
    Helpers.intersperse_map(fields, ", ", &[name, ?. | Helpers.quote_name(&1)])
  end

  def expr({:in, _, [_left, []]}, _sources, _query) do
    "0=1"
  end

  def expr({:in, _, [left, right]}, sources, query) when is_list(right) do
    args = Helpers.intersperse_map(right, ?,, &expr(&1, sources, query))
    [expr(left, sources, query), " IN (", args, ?)]
  end

  def expr({:in, _, [_, {:^, _, [_, 0]}]}, _sources, _query) do
    "0=1"
  end

  def expr({:in, _, [left, {:^, _, [ix, length]}]}, sources, query) do
    args =
        Enum.map(ix+1..ix+length, fn (i) -> [??, to_string(i)] end)
        |> Enum.intersperse(?,)
    [expr(left, sources, query), " IN (", args, ?)]
  end

  def expr({:in, _, [left, right]}, sources, query) do
    [expr(left, sources, query), " = ANY(", expr(right, sources, query), ?)]
  end

  def expr({:is_nil, _, [arg]}, sources, query) do
    [expr(arg, sources, query) | " IS NULL"]
  end

  def expr({:not, _, [expr]}, sources, query) do
    case expr do
      {fun, _, _} when fun in @binary_ops ->
        ["NOT (", expr(expr, sources, query), ?)]
      _ ->
        ["~(", expr(expr, sources, query), ?)]
    end
  end

  def expr(%Ecto.SubQuery{query: query, params: params}, _sources, _query) do
    query.select.fields |> put_in(params) |> Connection.all()
  end

  def expr({:fragment, _, [kw]}, _sources, query) when is_list(kw) or tuple_size(kw) == 3 do
    Helpers.error!(query, "ClickHouse adapter does not support keyword or interpolated fragments")
  end

  def expr({:fragment, _, parts}, sources, query) do
    Enum.map(parts, fn
      {:raw, part}  -> part
      {:expr, expr} -> expr(expr, sources, query)
    end)
  end

  def expr({:datetime_add, _, [datetime, count, interval]}, sources, query) do
    ["CAST(DATEADD(", interval, ",", expr(count, sources, query),
      ",", expr(datetime, sources, query) | ") AS DATETIME2)"]
  end

  def expr({:date_add, _, [date, count, interval]}, sources, query) do
    ["CAST(DATEADD(", interval, ",", expr(count, sources, query),
      ",", expr(date, sources, query) | ") AS DATE)"]
  end

  def expr({fun, _, args}, sources, query) when is_atom(fun) and is_list(args) do
    {modifier, args} =
      case args do
        [rest, :distinct] -> {"DISTINCT ", [rest]}
        _ -> {[], args}
      end

    case handle_call(fun, length(args)) do
      {:binary_op, op} ->
        [left, right] = args
        [op_to_binary(left, sources, query), op | op_to_binary(right, sources, query)]
      {:fun, fun} ->
        [fun, ?(, modifier, Helpers.intersperse_map(args, ", ", &expr(&1, sources, query)), ?)]
    end
  end

  def expr(list, sources, query) when is_list(list) do
    ["ARRAY[", Helpers.intersperse_map(list, ?,, &expr(&1, sources, query)), ?]]
  end

  def expr(%Decimal{} = decimal, _sources, _query) do
    Decimal.to_string(decimal, :normal)
  end

  def expr(%Ecto.Query.Tagged{value: binary, type: :binary}, _sources, _query)
      when is_binary(binary) do
    ["0x", Base.encode16(binary, case: :lower)]
  end

  def expr(%Ecto.Query.Tagged{value: other, type: type}, sources, query) do
    ["CAST(", expr(other, sources, query), " AS ", Helpers.ecto_to_db(type), ")"]
  end

  def expr(nil, _sources, _query),   do: "NULL"
  def expr(true, _sources, _query),  do: "1"
  def expr(false, _sources, _query), do: "0"

  def expr(literal, _sources, _query) when is_binary(literal) do
    [?\', Helpers.escape_string(literal), ?\']
  end

  def expr(literal, _sources, _query) when is_integer(literal) do
    Integer.to_string(literal)
  end

  def expr(literal, _sources, _query) when is_float(literal) do
    Float.to_string(literal)
  end

  def interval(count, _interval, sources, query) do
    [expr(count, sources, query)]
  end

  def op_to_binary({op, _, [_, _]} = expr, sources, query) when op in @binary_ops do
    paren_expr(expr, sources, query)
  end

  def op_to_binary(expr, sources, query) do
    expr(expr, sources, query)
  end

  def returning(%Query{select: nil}, _sources),
    do: []
  def returning(%Query{select: %{fields: fields}} = query, sources),
    do: [" RETURNING " | select_fields(fields, sources, query)]

  def returning([]),
    do: []
  def returning(returning),
    do: [" RETURNING " | Helpers.intersperse_map(returning, ", ", &Helpers.quote_name/1)]

  def create_names(%{prefix: prefix, sources: sources}) do
    create_names(prefix, sources, 0, tuple_size(sources)) |> List.to_tuple()
  end

  def create_names(prefix, sources, pos, limit) when pos < limit do
    current =
      case elem(sources, pos) do
        {table, schema} ->
          name = [String.first(table) | Integer.to_string(pos)]
          {Helpers.quote_table(prefix, table), name, schema}
        {:fragment, _, _} ->
          {nil, [?f | Integer.to_string(pos)], nil}
        %Ecto.SubQuery{} ->
          {nil, [?s | Integer.to_string(pos)], nil}
      end
    [current | create_names(prefix, sources, pos + 1, limit)]
  end

  def create_names(_prefix, _sources, pos, pos) do
    []
  end
end