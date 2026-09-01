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
      assert Map.has_key?(status, :docker_socket_available?)
      assert Map.has_key?(status, :is_upgrading?)
    end
  end
end
