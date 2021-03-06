defmodule Ecto.Repo.Schema do
  # The module invoked by user defined repos
  # for model related functionality.
  @moduledoc false

  alias Ecto.Query.Planner
  alias Ecto.Changeset
  alias Ecto.Changeset.Relation

  @doc """
  Implementation for `Ecto.Repo.insert!/2`.
  """
  def insert!(repo, adapter, model_or_changeset, opts) do
    case insert(repo, adapter, model_or_changeset, opts) do
      {:ok, model} -> model
      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  @doc """
  Implementation for `Ecto.Repo.update!/2`.
  """
  def update!(repo, adapter, model_or_changeset, opts) do
    case update(repo, adapter, model_or_changeset, opts) do
      {:ok, model} -> model
      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :update, changeset: changeset
    end
  end

  @doc """
  Implementation for `Ecto.Repo.delete!/2`.
  """
  def delete!(repo, adapter, model_or_changeset, opts) do
    case delete(repo, adapter, model_or_changeset, opts) do
      {:ok, model} -> model
      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :delete, changeset: changeset
    end
  end

  @doc """
  Implementation for `Ecto.Repo.insert/2`.
  """
  def insert(repo, adapter, %Changeset{} = changeset, opts) when is_list(opts) do
    do_insert(repo, adapter, changeset, opts)
  end

  def insert(repo, adapter, %{__struct__: _} = struct, opts) when is_list(opts) do
    changeset = Ecto.Changeset.change(struct)
    do_insert(repo, adapter, changeset, opts)
  end

  defp do_insert(repo, adapter, %Changeset{valid?: true, prepare: prepare} = changeset, opts) do
    struct = struct_from_changeset!(:insert, changeset)
    model  = struct.__struct__
    fields = model.__schema__(:fields)
    embeds = model.__schema__(:embeds)
    assocs = model.__schema__(:associations)
    return = model.__schema__(:read_after_writes)

    # On insert, we always merge the whole struct into the
    # changeset as changes, except the primary key if it is nil.
    changeset = update_changeset(changeset, :insert, repo)
    changeset = Relation.surface(changeset, fields, embeds, assocs)

    wrap_in_transaction(repo, adapter, opts, assocs, prepare, fn ->
      user_changeset = run_prepare(changeset, prepare)

      changeset = Ecto.Embedded.prepare(user_changeset, adapter, :insert)
      {assoc_changes, changeset} = pop_from_changes(changeset, assocs)

      changes = changeset.changes
      {autogen, changes} = pop_autogenerate_id(changes, model)
      {changes, extra} = dump_changes(:insert, changes, model, fields, adapter)

      args = [repo, metadata(struct), changes, autogen, return, opts]
      case apply(changeset, adapter, :insert, args) do
        {:ok, values} ->
          opts = Keyword.put(opts, :skip_transaction, true)
          changeset
          |> load_changes(:loaded, extra ++ values, adapter)
          |> process_assocs(assoc_changes, opts)
          |> get_model_if_ok(user_changeset)
        {:error, _} = error ->
          error
        {:invalid, constraints} ->
          {:error, constraints_to_errors(user_changeset, :insert, constraints)}
      end
    end)
  end

  defp do_insert(repo, _adapter, %Changeset{valid?: false} = changeset, _opts) do
    {:error, update_changeset(changeset, :insert, repo)}
  end

  @doc """
  Implementation for `Ecto.Repo.update/2`.
  """
  def update(repo, adapter, %Changeset{} = changeset, opts) when is_list(opts) do
    do_update(repo, adapter, changeset, opts)
  end

  def update(repo, _adapter, _struct, opts) when is_list(opts) do
    raise ArgumentError, "giving a struct to #{inspect repo}.update/2 is not supported. " <>
                         "Ecto is unable to properly track changes when a struct is given, " <>
                         "an Ecto.Changeset must be given instead"
  end

  defp do_update(repo, adapter, %Changeset{valid?: true, prepare: prepare} = changeset, opts) do
    struct = struct_from_changeset!(:update, changeset)
    model  = struct.__struct__
    fields = model.__schema__(:fields)
    assocs = model.__schema__(:associations)
    return = model.__schema__(:read_after_writes)

    # Differently from insert, update does not copy the struct
    # fields into the changeset. All changes must be in the
    # changeset before hand.
    changeset = update_changeset(changeset, :update, repo)

    if changeset.changes != %{} or opts[:force] do
      wrap_in_transaction(repo, adapter, opts, assocs, prepare, fn ->
        user_changeset = run_prepare(changeset, prepare)

        changeset = Ecto.Embedded.prepare(user_changeset, adapter, :update)
        {assoc_changes, changeset} = pop_from_changes(changeset, assocs)

        changes = changeset.changes
        autogen = get_autogenerate_id(changes, model)
        {changes, extra} = dump_changes(:update, changes, model, fields, adapter)

        filters = add_pk_filter!(changeset.filters, struct)
        filters = Planner.fields(model, :update, filters, adapter)

        args   = [repo, metadata(struct), changes, filters, autogen, return, opts]
        action = if changes == [], do: :noop, else: :update
        case apply(changeset, adapter, action, args) do
          {:ok, values} ->
            opts = Keyword.put(opts, :skip_transaction, true)
            changeset
            |> load_changes(:loaded, extra ++ values, adapter)
            |> process_assocs(assoc_changes, opts)
            |> get_model_if_ok(user_changeset)
          {:error, _} = error ->
            error
          {:invalid, constraints} ->
            {:error, constraints_to_errors(user_changeset, :update, constraints)}
        end
      end)
    else
      {:ok, changeset.model}
    end
  end

  defp do_update(repo, _adapter, %Changeset{valid?: false} = changeset, _opts) do
    {:error, update_changeset(changeset, :update, repo)}
  end

  @doc """
  Implementation for `Ecto.Repo.insert_or_update/2`.
  """
  def insert_or_update(repo, adapter, changeset, opts) do
    case get_state(changeset) do
      :built  -> insert repo, adapter, changeset, opts
      :loaded -> update repo, adapter, changeset, opts
      state   -> raise ArgumentError, "the changeset has an invalid state " <>
                                      "for Repo.insert_or_update/2: #{state}"
    end
  end

  @doc """
  Implementation for `Ecto.Repo.insert_or_update!/2`.
  """
  def insert_or_update!(repo, adapter, changeset, opts) do
    case get_state(changeset) do
      :built  -> insert! repo, adapter, changeset, opts
      :loaded -> update! repo, adapter, changeset, opts
      state   -> raise ArgumentError, "the changeset has an invalid state " <>
                                      "for Repo.insert_or_update!/2: #{state}"
    end
  end

  defp get_state(%Changeset{model: model}), do: model.__meta__.state
  defp get_state(%{__struct__: _model}) do
    raise ArgumentError, "giving a struct to Repo.insert_or_update/2 or " <>
                         "Repo.insert_or_update!/2 is not supported. " <>
                         "Please use an Ecto.Changeset"
  end

  @doc """
  Implementation for `Ecto.Repo.delete/2`.
  """
  def delete(repo, adapter, %Changeset{} = changeset, opts) when is_list(opts) do
    do_delete(repo, adapter, changeset, opts)
  end

  def delete(repo, adapter, %{__struct__: _} = struct, opts) when is_list(opts) do
    changeset = Ecto.Changeset.change(struct)
    do_delete(repo, adapter, changeset, opts)
  end

  defp do_delete(repo, adapter, %Changeset{valid?: true, prepare: prepare} = changeset, opts) do
    struct = struct_from_changeset!(:delete, changeset)
    model  = struct.__struct__
    assocs = model.__schema__(:associations)

    changeset = update_changeset(changeset, :delete, repo)
    changeset = %{changeset | changes: %{}}
    autogen   = get_autogenerate_id(changeset, model)

    wrap_in_transaction(repo, adapter, opts, assocs, prepare, fn ->
      changeset = run_prepare(changeset, prepare)

      filters = add_pk_filter!(changeset.filters, struct)
      filters = Planner.fields(model, :delete, filters, adapter)

      delete_assocs(changeset, repo, model, assocs, opts)
      args = [repo, metadata(struct), filters, autogen, opts]
      case apply(changeset, adapter, :delete, args) do
        {:ok, values} ->
          {:ok, load_changes(changeset, :deleted, values, adapter).model}
        {:error, _} = error ->
          error
        {:invalid, constraints} ->
          {:error, constraints_to_errors(changeset, :delete, constraints)}
      end
    end)
  end

  defp do_delete(repo, _adapter, %Changeset{valid?: false} = changeset, _opts) do
    {:error, update_changeset(changeset, :delete, repo)}
  end

  ## Helpers

  defp struct_from_changeset!(action, %{model: nil}),
    do: raise(ArgumentError, "cannot #{action} a changeset without a model")
  defp struct_from_changeset!(_action, %{model: struct}),
    do: struct

  defp update_changeset(%{action: given}, action, repo) when given != nil and given != action,
    do: raise(ArgumentError, "a changeset with action #{inspect given} was given to #{inspect repo}.#{action}/2")
  defp update_changeset(changeset, action, repo),
    do: %{changeset | action: action, repo: repo}

  defp run_prepare(changeset, prepare) do
    Enum.reduce(Enum.reverse(prepare), changeset, fn fun, acc ->
      case fun.(acc) do
        %Ecto.Changeset{} = acc -> acc
        other ->
          raise "expected function #{inspect fun} given to Ecto.Changeset.prepare_changes/2 " <>
                "to return an Ecto.Changeset, got: `#{inspect other}`"
      end
    end)
  end

  defp metadata(%{__struct__: model, __meta__: meta}) do
    meta
    |> Map.delete(:__struct__)
    |> Map.put(:model, model)
  end

  defp apply(%{valid?: false} = changeset, _adapter, _action, _args) do
    {:error, changeset}
  end
  defp apply(_changeset, _adapter, :noop, _args) do
    {:ok, []}
  end
  defp apply(changeset, adapter, action, args) do
    case apply(adapter, action, args) do
      {:ok, values} ->
        {:ok, values}
      {:invalid, _} = constraints ->
        constraints
      {:error, :stale} ->
        raise Ecto.StaleEntryError, model: changeset.model, action: action
    end
  end

  defp constraints_to_errors(%{constraints: user_constraints} = changeset, action, constraints) do
    Enum.reduce constraints, changeset, fn {type, constraint}, acc ->
      user_constraint =
        Enum.find(user_constraints, fn c ->
          c.type == type and c.constraint == constraint
        end)

      case user_constraint do
        %{field: field, message: message} ->
          Ecto.Changeset.add_error(acc, field, message)
        nil ->
          raise Ecto.ConstraintError, action: action, type: type,
                                      constraint: constraint, changeset: changeset
      end
    end
  end

  defp load_changes(%{types: types, changes: changes} = changeset, state, values, adapter) do
    # It is ok to use types from changeset because we have
    # already filtered the results to be only about fields.
    model =
      changeset.model
      |> Map.merge(changes)
      |> load_each(values, types, adapter)
    model = put_in(model.__meta__.state, state)
    Map.put(changeset, :model, model)
  end

  defp load_each(struct, kv, types, adapter) do
    Enum.reduce(kv, struct, fn {k, v}, acc ->
      type = Map.fetch!(types, k)
      case adapter.load(type, v) do
        {:ok, v} -> Map.put(acc, k, v)
        :error   -> raise ArgumentError, "cannot load `#{inspect v}` as type #{inspect type}"
      end
    end)
  end

  defp pop_from_changes(changeset, fields) do
    get_and_update_in(changeset.changes, &Map.split(&1, fields))
  end

  defp process_assocs(changeset, assocs, opts) do
    Ecto.Association.on_repo_change(:child, changeset, assocs, opts)
  end

  defp delete_assocs(%{model: model}, repo, struct, assocs, opts) do
    for assoc_name <- assocs do
      case struct.__schema__(:association, assoc_name) do
        %{__struct__: mod, on_delete: on_delete} = reflection when on_delete != :nothing ->
          apply(mod, on_delete, [reflection, model, repo, opts])
        _ ->
          :ok
      end
    end

    :ok
  end

  defp get_model_if_ok({:ok, %{model: model}}, _user_changeset) do
    {:ok, model}
  end

  defp get_model_if_ok({:error, %{changes: changes}}, user_changeset) do
    {:error, %{user_changeset | valid?: false, changes: changes}}
  end

  defp pop_autogenerate_id(changes, model) do
    case model.__schema__(:autogenerate_id) do
      {key, id} ->
        case Map.pop(changes, key) do
          {nil, changes} -> {{key, id, nil}, changes}
          {value, _}     -> {{key, id, value}, changes}
        end
      nil ->
        {nil, changes}
    end
  end

  defp get_autogenerate_id(changes, model) do
    case model.__schema__(:autogenerate_id) do
      {key, id} -> {key, id, Map.get(changes, key)}
      nil -> nil
    end
  end

  defp dump_changes(action, changes, model, fields, adapter) do
    changes = Map.take(changes, fields)
    {leftover, autogen} = autogenerate_changes(model, action, changes)
    dumped = Planner.fields(model, action, leftover, adapter)
    {autogen ++ dumped, autogen}
  end

  defp autogenerate_changes(model, action, changes) do
    Enum.reduce model.__schema__(:autogenerate, action), {changes, []},
      fn {k, mod, args}, {acc_changes, acc_autogen} ->
        case Map.get(acc_changes, k) do
          nil -> {Map.delete(acc_changes, k), [{k, apply(mod, :autogenerate, args)}|acc_autogen]}
          _   -> {acc_changes, acc_autogen}
        end
      end
  end

  defp add_pk_filter!(filters, struct) do
    Enum.reduce Ecto.primary_key!(struct), filters, fn
      {_k, nil}, _acc ->
        raise Ecto.NoPrimaryKeyValueError, struct: struct
      {k, v}, acc ->
        Map.put(acc, k, v)
    end
  end

  defp wrap_in_transaction(repo, adapter, opts, assocs, prepare, fun) do
    if (assocs != [] or prepare != []) and
       Keyword.get(opts, :skip_transaction) != true and
       function_exported?(adapter, :transaction, 3) do
      adapter.transaction(repo, opts, fn ->
        case fun.() do
          {:ok, model} -> model
          {:error, changeset} -> adapter.rollback(repo, changeset)
        end
      end)
    else
      fun.()
    end
  end
end
