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
end
