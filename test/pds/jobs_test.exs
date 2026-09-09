defmodule Aerox.PDS.JobsTest do
  use Aerox.DataCase, async: false
  use Oban.Testing, repo: Aerox.PDS.Repo
  import Ecto.Query
  alias Aerox.PDS.{Jobs, Repo}
  alias Aerox.PDS.Schema.{Actor, RefreshToken}

  test "RevokeExpiredTokens prunes only expired refresh tokens" do
    kp = Aerox.ATProto.Crypto.generate(:k256)
    did = "did:plc:" <> String.duplicate("a", 24)

    {:ok, _} =
      Aerox.PDS.Accounts.register(%{
        did: did,
        handle: "jobs.test",
        email: "jobs@example.com",
        password: "pw",
        signing_key: kp.private
      })

    now = DateTime.utc_now()

    Repo.insert_all(RefreshToken, [
      %{id: "old", did: did, expires_at: DateTime.add(now, -10, :second)},
      %{id: "fresh", did: did, expires_at: DateTime.add(now, 3600, :second)}
    ])

    assert :ok = perform_job(Jobs.RevokeExpiredTokens, %{})
    assert ["fresh"] = Repo.all(from(t in RefreshToken, select: t.id))
    assert Repo.exists?(from(a in Actor, where: a.did == ^did))
  end

  test "ReapBlobs without a did fans out one job per actor; with a did it reaps" do
    assert :ok = perform_job(Jobs.ReapBlobs, %{})
    assert :ok = perform_job(Jobs.ReapBlobs, %{"did" => "did:plc:" <> String.duplicate("b", 24)})
    assert :ok = perform_job(Jobs.ReapSignups, %{})
  end
end
