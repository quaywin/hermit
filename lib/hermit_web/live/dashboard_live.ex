defmodule HermitWeb.DashboardLive do
  use HermitWeb, :live_view
  alias Hermit.Vpn.Form
  alias Hermit.Vpn.PairWorker
  alias Hermit.Vpn.DynamicSupervisor

  @topic "vpn_pairs"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Hermit.PubSub, @topic)
    end

    pairs = PairWorker.list_pairs()
    ts_key = Hermit.Vpn.Setting.get_value("tailscale_auth_key", "")
    ts_api_key = Hermit.Vpn.Setting.get_value("tailscale_api_key", "")
    ts_tailnet = Hermit.Vpn.Setting.get_value("tailscale_tailnet", "")

    {:ok,
     socket
     |> stream(:vpn_pairs, pairs)
     |> assign(global_ts_auth_key: ts_key)
     |> assign(global_ts_api_key: ts_api_key)
     |> assign(global_ts_tailnet: ts_tailnet)
     |> assign_form()}
  end

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    changeset =
      %Form{}
      |> Form.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"form" => params}, socket) do
    changeset = Form.changeset(%Form{}, params)

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, data} ->
        ts_auth_key =
          if is_nil(data.ts_auth_key) || data.ts_auth_key == "" do
            Hermit.Vpn.Setting.get_value("tailscale_auth_key") ||
              Application.get_env(:hermit, :docker)[:tailscale_auth_key]
          else
            data.ts_auth_key
          end

        case DynamicSupervisor.start_pair(%{
               id: data.pair_id,
               wg_config: data.wg_config,
               ts_auth_key: ts_auth_key
             }) do
          {:ok, _pid} ->
            {:noreply,
             socket
             |> put_flash(:info, "VPN Pair '#{data.pair_id}' started bootstrapping.")
             |> assign_form()}

          {:error, {:already_started, _}} ->
            {:noreply,
             put_flash(socket, :error, "VPN Pair with ID '#{data.pair_id}' is already running.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to start VPN Pair: #{inspect(reason)}")}
        end

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("save_settings", params, socket) do
    auth_key = Map.get(params, "tailscale_auth_key", "")
    api_key = Map.get(params, "tailscale_api_key", "")
    tailnet = Map.get(params, "tailscale_tailnet", "")

    cond do
      auth_key != "" and not String.starts_with?(auth_key, "tskey-") ->
        {:noreply, put_flash(socket, :error, "Tailscale Auth Key must start with 'tskey-'")}

      api_key != "" and not String.starts_with?(api_key, "tskey-api-") ->
        {:noreply, put_flash(socket, :error, "Tailscale API Key must start with 'tskey-api-'")}

      true ->
        with {:ok, _} <- Hermit.Vpn.Setting.put_value("tailscale_auth_key", auth_key),
             {:ok, _} <- Hermit.Vpn.Setting.put_value("tailscale_api_key", api_key),
             {:ok, _} <- Hermit.Vpn.Setting.put_value("tailscale_tailnet", tailnet) do
          {:noreply,
           socket
           |> assign(global_ts_auth_key: auth_key)
           |> assign(global_ts_api_key: api_key)
           |> assign(global_ts_tailnet: tailnet)
           |> put_flash(:info, "Global Settings updated successfully.")}
        else
          {:error, changeset} ->
            error_msg =
              changeset.errors
              |> Enum.map(fn {field, {msg, _}} -> "#{field} #{msg}" end)
              |> Enum.join(", ")

            {:noreply, put_flash(socket, :error, "Failed to save settings: #{error_msg}")}
        end
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case DynamicSupervisor.stop_pair(id) do
      :ok ->
        {:noreply, put_flash(socket, :info, "VPN Pair '#{id}' deleted.")}

      {:error, :not_found} ->
        # Force clean up in UI if process is already dead
        {:noreply,
         socket
         |> stream_delete(:vpn_pairs, %{id: id})
         |> put_flash(:info, "VPN Pair '#{id}' deleted.")}
    end
  end

  @impl true
  def handle_info({:vpn_pair_updated, state}, socket) do
    {:noreply, stream_insert(socket, :vpn_pairs, state)}
  end

  @impl true
  def handle_info({:vpn_pair_deleted, id}, socket) do
    {:noreply, stream_delete(socket, :vpn_pairs, %{id: id})}
  end

  # --- Helpers ---

  defp assign_form(socket) do
    changeset = Form.changeset(%Form{}, %{})
    assign(socket, form: to_form(changeset))
  end

  def format_uptime(nil), do: "-"

  def format_uptime(started_at) do
    diff = max(0, System.system_time(:second) - started_at)

    cond do
      diff < 60 -> "#{diff}s"
      diff < 3600 -> "#{div(diff, 60)}m #{rem(diff, 60)}s"
      true -> "#{div(diff, 3600)}h #{rem(div(diff, 60), 60)}m"
    end
  end

  def format_bytes(nil), do: "0 B"

  def format_bytes(bytes) do
    cond do
      bytes < 1024 -> "#{bytes} B"
      bytes < 1024 * 1024 -> "#{Float.round(bytes / 1024, 1)} KiB"
      true -> "#{Float.round(bytes / (1024 * 1024), 2)} MiB"
    end
  end
end
