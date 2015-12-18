defmodule Ecto.Multi do
  alias __MODULE__
  alias Ecto.Changeset

  defstruct operations: [], names: MapSet.new

  @type run :: (t, Keyword.t -> {:ok | :error, any}) | {module, atom, [any]}
  @type operation :: {:changeset, Changeset.t} |
                     {:run, run} |
                     {:update_all, Ecto.Query.t, Keyword.t} |
                     {:delete_all, Ecto.Query.t}
  @type name :: atom
  @type t :: %__MODULE__{operations: [{name, operation}], names: MapSet.t}

  @spec new :: t
  def new do
    %Multi{}
  end

  @spec append(t, t) :: t
  def append(lhs, rhs) do
    merge(lhs, rhs, &(&2 ++ &1))
  end

  @spec prepend(t, t) :: t
  def prepend(lhs, rhs) do
    merge(lhs, rhs, &(&1 ++ &2))
  end

  def merge(%Multi{names: names1, operations: ops1} = lhs,
            %Multi{names: names2, operations: ops2} = rhs,
            joiner) do
    if MapSet.disjoint?(names1, names2) do
      %Multi{names: MapSet.union(names1, names2),
             operations: joiner.(ops1, ops2)}
    else
      common = MapSet.intersection(names1, names2) |> MapSet.to_list
      raise """
      When merging following Ecto.Multi:

      #{inspect lhs}

      #{inspect rhs}

      both declared operations: #{inspect common}
      """
    end
  end

  @spec insert(t, name, Changeset.t | Model.t) :: t
  def insert(multi, name, %Changeset{} = changeset) do
    add_changeset(multi, :insert, name, changeset)
  end

  def insert(multi, name, struct) do
    insert(multi, name, Changeset.change(struct))
  end

  @spec update(t, name, Changeset.t) :: t
  def update(multi, name, %Changeset{} = changeset) do
    add_changeset(multi, :update, name, changeset)
  end

  @spec delete(t, name, Changeset.t | Model.t) :: t
  def delete(multi, name, %Changeset{} = changeset) do
    add_changeset(multi, :delete, name, changeset)
  end

  def delete(multi, name, struct) do
    delete(multi, name, Changeset.change(struct))
  end

  defp add_changeset(multi, action, name, changeset) do
    add_operation(multi, name, {:changeset, put_action(changeset, action)})
  end

  defp put_action(%{action: nil} = changeset, action) do
    %{changeset | action: action}
  end

  defp put_action(%{action: action} = changeset, action) do
    changeset
  end

  defp put_action(%{action: original}, action) do
    raise ArgumentError, "you provided a changeset with an action already set " <>
      "to #{inspect original} when trying to #{action} it"
  end

  @spec run(t, name, run) :: t
  def run(multi, name, run) when is_function(run, 2) do
    add_operation(multi, name, {:run, run})
  end

  @spec run(t, name, module, function, args) :: t
    when function: atom, args: [any]
  def run(multi, name, mod, fun, args) do
    add_operation(multi, name, {:run, {mod, fun, args}})
  end

  @spec update_all(t, name, Ecto.Queryable.t, Keyword.t) :: t
  def update_all(multi, name, queryable, updates) do
    query = Ecto.Queryable.to_query(queryable)
    add_operation(multi, name, {:update_all, query, updates})
  end

  @spec delete_all(t, name, Ecto.Queryable.t) :: t
  def delete_all(multi, name, queryable) do
    query = Ecto.Queryable.to_query(queryable)
    add_operation(multi, name, {:delete_all, query})
  end

  defp add_operation(%Multi{operations: operations, names: names} = multi, name,
                     operation) when is_atom(name) do
    if MapSet.member?(names, name) do
      raise "#{inspect name} is already a member of the Ecto.Multi: \n#{inspect multi}"
    else
      %{multi | operations: [{name, operation} | operations],
                names: MapSet.put(names, name)}
    end
  end

  def to_list(%Multi{operations: operations}) do
    operations
    |> Enum.reverse
    |> Enum.map(&format_operation/1)
  end

  defp format_operation({name, {:changeset, changeset}}),
    do: {name, {changeset.action, changeset}}
  defp format_operation(other),
    do: other

  @spec apply(t, Ecto.Repo.t, wrap, return, Keyword.t) ::
      {:ok, results} | {:error, {name, error, results}}
    when results: %{name => Ecto.Schema.t | any},
         error: Changeset.t | any,
         wrap: ((() -> any) -> {:ok | :error, any}),
         return: (any -> no_return)
  def apply(%Multi{} = multi, repo, wrap, return, opts \\ []) do
    multi.operations
    |> Enum.reverse
    |> check_operations_valid
    |> apply_operations(repo, wrap, return, opts)
  end

  defp check_operations_valid(operations) do
    case Enum.find(operations, &invalid_operation?/1) do
      nil                             -> {:ok, operations}
      {name, {:changeset, changeset}} -> {:error, {name, changeset, %{}}}
    end
  end

  defp invalid_operation?({_, {:changeset, %{valid?: valid?}}}), do: not valid?
  defp invalid_operation?(_operation),                           do: false

  defp apply_operations({:ok, operations}, repo, wrap, return, opts) do
    wrap.(fn ->
      Enum.reduce(operations, %{}, &apply_operation(&1, repo, return, opts, &2))
    end)
  end

  defp apply_operations({:error, error}, _repo, _wrap, _return, _opts) do
    {:error, error}
  end

  defp apply_operation({name, operation}, repo, return, opts, acc) do
    case apply_operation(operation, acc, repo, opts) do
      {:ok, value} ->
        Map.put(acc, name, value)
      {:error, value} ->
        return.({name, value, acc})
    end
  end

  defp apply_operation({:changeset, changeset}, _acc, repo, opts),
    do: apply(repo, changeset.action, [changeset, opts])
  defp apply_operation({:run, {mod, fun, args}}, acc, _repo, opts),
    do: apply(mod, fun, [acc, opts | args])
  defp apply_operation({:run, run}, acc, _repo, opts),
    do: apply(run, [acc, opts])
  defp apply_operation({:update_all, query, updates}, _acc, repo, opts),
    do: {:ok, repo.update_all(query, updates, opts)}
  defp apply_operation({:delete_all, query}, _acc, repo, opts),
    do: {:ok, repo.delete_all(query, opts)}
end