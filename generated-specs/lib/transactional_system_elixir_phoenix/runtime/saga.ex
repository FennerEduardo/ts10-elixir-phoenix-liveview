defmodule TransactionalSystemElixirPhoenix.Runtime.Saga do
  @moduledoc """
  Orchestrated saga: progress is persisted after every step; when a step fails, the completed
  steps are compensated in reverse order. Re-running a saga id resumes after its completed steps.
  Steps are %{name: String.t(), action: (-> any), compensate: (-> any)}.
  """
  alias TransactionalSystemElixirPhoenix.Runtime.Schema

  def run(conn, schema, saga_id, tenant_id, steps) do
    s = Schema.name(schema)
    Postgrex.query!(conn, "INSERT INTO #{s}.ghk_sagas (id, tenant_id, status) VALUES ($1, $2, 'RUNNING') ON CONFLICT (id) DO NOTHING", [saga_id, tenant_id])
    completed = (status(conn, schema, saga_id) || %{completed_steps: []}).completed_steps
    advance(conn, s, saga_id, steps, steps, completed)
  end

  defp advance(conn, s, saga_id, [], _all, completed) do
    save(conn, s, saga_id, "COMPLETED", completed)
    "COMPLETED"
  end

  defp advance(conn, s, saga_id, [step | rest], all, completed) do
    if step.name in completed do
      advance(conn, s, saga_id, rest, all, completed)
    else
      try do
        step.action.()
        completed = completed ++ [step.name]
        save(conn, s, saga_id, "RUNNING", completed)
        advance(conn, s, saga_id, rest, all, completed)
      rescue
        _ -> compensate(conn, s, saga_id, all, completed)
      end
    end
  end

  defp compensate(conn, s, saga_id, all, completed) do
    save(conn, s, saga_id, "COMPENSATING", completed)

    remaining =
      Enum.reduce(Enum.reverse(completed), completed, fn name, acc ->
        Enum.find(all, &(&1.name == name)).compensate.()
        acc = List.delete(acc, name)
        save(conn, s, saga_id, "COMPENSATING", acc)
        acc
      end)

    save(conn, s, saga_id, "COMPENSATED", remaining)
    "COMPENSATED"
  end

  def status(conn, schema, saga_id) do
    case Postgrex.query!(conn, "SELECT status, completed_steps FROM #{Schema.name(schema)}.ghk_sagas WHERE id = $1", [saga_id]).rows do
      [[status, ""]] -> %{status: status, completed_steps: []}
      [[status, done]] -> %{status: status, completed_steps: String.split(done, ",")}
      [] -> nil
    end
  end

  defp save(conn, s, saga_id, status, completed) do
    Postgrex.query!(conn, "UPDATE #{s}.ghk_sagas SET status = $2, completed_steps = $3, updated_at = now() WHERE id = $1", [saga_id, status, Enum.join(completed, ",")])
  end
end
