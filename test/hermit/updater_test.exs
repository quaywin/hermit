defmodule Hermit.UpdaterTest do
  use ExUnit.Case, async: true
  alias Hermit.Updater

  describe "is_newer_version?/2" do
    test "correctly detects newer semver versions" do
      assert Updater.is_newer_version?("0.2.1", "0.2.2")
      assert Updater.is_newer_version?("0.2.1", "0.3.0")
      assert Updater.is_newer_version?("0.2.1", "1.0.0")
      assert Updater.is_newer_version?("v0.2.1", "v0.2.43")
      assert Updater.is_newer_version?("0.2.1", "v0.2.43")
    end

    test "correctly detects older or equal versions" do
      refute Updater.is_newer_version?("0.2.1", "0.2.1")
      refute Updater.is_newer_version?("v0.2.1", "0.2.1")
      refute Updater.is_newer_version?("0.2.2", "0.2.1")
      refute Updater.is_newer_version?("1.0.0", "0.9.9")
    end

    test "handles invalid or empty strings gracefully" do
      refute Updater.is_newer_version?("0.2.1", "")
      refute Updater.is_newer_version?("", "")
      refute Updater.is_newer_version?(nil, "0.2.1")
      refute Updater.is_newer_version?("0.2.1", nil)
    end
  end

  describe "current_version/0" do
    test "returns a valid version string" do
      version = Updater.current_version()
      assert is_binary(version)
      assert version != ""
    end
  end

  describe "status/0" do
    test "returns status map with expected fields" do
      status = Updater.status()
      assert is_map(status)
      assert Map.has_key?(status, :current_version)
      assert Map.has_key?(status, :latest_version)
      assert Map.has_key?(status, :update_available?)
      assert Map.has_key?(status, :native_upgrade_available?)
      assert Map.has_key?(status, :is_upgrading?)
    end
  end

  describe "verify_sha256_against_sums/3" do
    test "returns :ok when file sha256 matches SHA256SUMS entry" do
      tmp = Path.join(System.tmp_dir!(), "hermit-sum-test-#{System.unique_integer([:positive])}")
      content = "hermit test payload"
      File.write!(tmp, content)
      on_exit(fn -> File.rm(tmp) end)

      expected_hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      sums = """
      0000000000000000000000000000000000000000000000000000000000000000  hermit-linux-arm64.tar.gz
      #{expected_hash}  hermit-linux-amd64.tar.gz
      """

      assert :ok == Updater.verify_sha256_against_sums(tmp, "hermit-linux-amd64.tar.gz", sums)
    end

    test "returns error on checksum mismatch or missing entry" do
      tmp = Path.join(System.tmp_dir!(), "hermit-sum-test-#{System.unique_integer([:positive])}")
      File.write!(tmp, "hermit test payload")
      on_exit(fn -> File.rm(tmp) end)

      sums = "deadbeef  hermit-linux-amd64.tar.gz\n"

      assert {:error, "Checksum mismatch for hermit-linux-amd64.tar.gz"} ==
               Updater.verify_sha256_against_sums(tmp, "hermit-linux-amd64.tar.gz", sums)

      assert {:error, "Checksum entry not found for hermit-linux-arm64.tar.gz"} ==
               Updater.verify_sha256_against_sums(tmp, "hermit-linux-arm64.tar.gz", sums)
    end
  end

  describe "prune_old_releases_in/2" do
    test "never deletes the active current release even when local-time release IDs sort higher than UTC ID" do
      root =
        Path.join(System.tmp_dir!(), "hermit-prune-utc-#{System.unique_integer([:positive])}")

      releases_dir = Path.join(root, "releases")
      old_local = Path.join(releases_dir, "20261124090000")
      newer_local = Path.join(releases_dir, "20261124100000")
      new_utc = Path.join(releases_dir, "20261124035140")

      File.mkdir_p!(old_local)
      File.mkdir_p!(newer_local)
      File.mkdir_p!(new_utc)
      File.ln_s!(new_utc, Path.join(root, "current"))
      on_exit(fn -> File.rm_rf!(root) end)

      assert :ok = Updater.prune_old_releases_in(root, new_utc)

      assert File.dir?(new_utc)
      assert File.dir?(newer_local)
      refute File.exists?(old_local)
    end

    test "keeps the two newest releases under normal descending order" do
      root =
        Path.join(System.tmp_dir!(), "hermit-prune-norm-#{System.unique_integer([:positive])}")

      releases_dir = Path.join(root, "releases")
      r1 = Path.join(releases_dir, "20261124010000")
      r2 = Path.join(releases_dir, "20261124020000")
      r3 = Path.join(releases_dir, "20261124030000")

      File.mkdir_p!(r1)
      File.mkdir_p!(r2)
      File.mkdir_p!(r3)
      File.ln_s!(r3, Path.join(root, "current"))
      on_exit(fn -> File.rm_rf!(root) end)

      assert :ok = Updater.prune_old_releases_in(root, r3)

      assert File.dir?(r3)
      assert File.dir?(r2)
      refute File.exists?(r1)
    end
  end
end
