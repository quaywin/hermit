defmodule HermitWeb.BlocklistLive do
  use HermitWeb, :live_view
  import Ecto.Query
  alias Hermit.Dns.Blocklist
  alias Hermit.Dns.BlocklistLoader
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if :erlang.whereis(Hermit.PubSub) != :undefined do
      Phoenix.PubSub.subscribe(Hermit.PubSub, "dns_blocklist")
    end

    blocklists = fetch_blocklists()
    update_interval = Hermit.Vpn.Setting.get_value("dns_blocklist_auto_update_interval", "24h")

    {:ok,
     socket
     |> assign(blocklists: blocklists)
     |> assign(show_modal: false)
     |> assign(editing_blocklist: nil)
     |> assign(update_interval: update_interval)
     |> assign(ram_usage: BlocklistLoader.get_memory_usage())
     |> assign(free_ram: BlocklistLoader.get_system_free_memory_string())
     |> assign_form()}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("open_create_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(show_modal: true, editing_blocklist: nil)
     |> assign_form(%Blocklist{})}
  end

  @impl true
  def handle_event("open_edit_modal", %{"id" => id}, socket) do
    blocklist = Hermit.Repo.get!(Blocklist, id)

    {:noreply,
     socket
     |> assign(show_modal: true, editing_blocklist: blocklist)
     |> assign_form(blocklist)}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, socket |> assign(show_modal: false, editing_blocklist: nil)}
  end

  @impl true
  def handle_event("validate_blocklist", %{"blocklist" => params}, socket) do
    struct = socket.assigns.editing_blocklist || %Blocklist{}
    changeset = Blocklist.changeset(struct, params) |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  @impl true
  def handle_event("save_blocklist", %{"blocklist" => params}, socket) do
    case socket.assigns.editing_blocklist do
      nil ->
        # Create
        changeset = Blocklist.changeset(%Blocklist{}, params)

        case Hermit.Repo.insert(changeset) do
          {:ok, blocklist} ->
            if blocklist.enabled do
              BlocklistLoader.load_blocklist_async(blocklist)
            end

            {:noreply,
             socket
             |> put_flash(:info, "Blocklist Filter source created successfully.")
             |> assign(blocklists: fetch_blocklists(), show_modal: false)}

          {:error, changeset} ->
            {:noreply, assign(socket, form: to_form(changeset))}
        end

      blocklist ->
        # Edit
        changeset = Blocklist.changeset(blocklist, params)
        was_enabled = blocklist.enabled
        old_url = blocklist.url
        old_format = blocklist.format

        case Hermit.Repo.update(changeset) do
          {:ok, updated_blocklist} ->
            # React to enabling/disabling or URL changes
            cond do
              not was_enabled and updated_blocklist.enabled ->
                # Enabled
                BlocklistLoader.load_blocklist_async(updated_blocklist)

              was_enabled and not updated_blocklist.enabled ->
                # Disabled
                BlocklistLoader.unload_blocklist(updated_blocklist.id)

              updated_blocklist.enabled and (old_url != updated_blocklist.url or old_format != updated_blocklist.format) ->
                # Changed config while enabled -> reload
                BlocklistLoader.load_blocklist_async(updated_blocklist)

              true ->
                :ok
            end

            {:noreply,
             socket
             |> put_flash(:info, "Blocklist Filter source updated successfully.")
             |> assign(blocklists: fetch_blocklists(), show_modal: false, editing_blocklist: nil)
             |> assign(ram_usage: BlocklistLoader.get_memory_usage())
             |> assign(free_ram: BlocklistLoader.get_system_free_memory_string())}

          {:error, changeset} ->
            {:noreply, assign(socket, form: to_form(changeset))}
        end
    end
  end

  @impl true
  def handle_event("toggle_blocklist", %{"id" => id}, socket) do
    blocklist = Hermit.Repo.get!(Blocklist, id)
    new_enabled = not blocklist.enabled
    changeset = Blocklist.changeset(blocklist, %{enabled: new_enabled})

    case Hermit.Repo.update(changeset) do
      {:ok, updated} ->
        if updated.enabled do
          BlocklistLoader.load_blocklist_async(updated)
          {:noreply,
           socket
           |> put_flash(:info, "Filter source '#{updated.name}' enabled. Loading rules...")
           |> assign(blocklists: fetch_blocklists())
           |> assign(ram_usage: BlocklistLoader.get_memory_usage())
           |> assign(free_ram: BlocklistLoader.get_system_free_memory_string())}
        else
          BlocklistLoader.unload_blocklist(updated.id)
          {:noreply,
           socket
           |> put_flash(:info, "Filter source '#{updated.name}' disabled.")
           |> assign(blocklists: fetch_blocklists())
           |> assign(ram_usage: BlocklistLoader.get_memory_usage())
           |> assign(free_ram: BlocklistLoader.get_system_free_memory_string())}
        end

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Failed to toggle filter source.")}
    end
  end

  @impl true
  def handle_event("fetch_blocklist", %{"id" => id}, socket) do
    blocklist = Hermit.Repo.get!(Blocklist, id)
    if blocklist.enabled do
      BlocklistLoader.load_blocklist_async(blocklist)
      {:noreply, socket |> put_flash(:info, "Update triggered for '#{blocklist.name}' in the background.")}
    else
      {:noreply, socket |> put_flash(:error, "Cannot trigger update for a disabled filter source.")}
    end
  end

  @impl true
  def handle_event("reload_all_blocklists", _params, socket) do
    Task.start(fn -> BlocklistLoader.reload_all() end)
    {:noreply, socket |> put_flash(:info, "All enabled blocklists reload triggered in the background.")}
  end

  @impl true
  def handle_event("change_update_interval", %{"interval" => interval}, socket) do
    Hermit.Vpn.Setting.put_value("dns_blocklist_auto_update_interval", interval)

    if :erlang.whereis(BlocklistLoader) != :undefined do
      send(BlocklistLoader, {:reschedule_update, interval})
    end

    {:noreply,
     socket
     |> assign(update_interval: interval)
     |> put_flash(:info, "Auto-update schedule updated successfully.")}
  end

  @impl true
  def handle_event("delete_blocklist", %{"id" => id}, socket) do
    blocklist = Hermit.Repo.get!(Blocklist, id)

    BlocklistLoader.unload_blocklist(blocklist.id)

    case Hermit.Repo.delete(blocklist) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Filter source deleted successfully.")
         |> assign(blocklists: fetch_blocklists())
         |> assign(ram_usage: BlocklistLoader.get_memory_usage())
         |> assign(free_ram: BlocklistLoader.get_system_free_memory_string())}

      {:error, _} ->
        {:noreply, socket |> put_flash(:error, "Failed to delete filter source.")}
    end
  end

  @impl true
  def handle_info({:blocklist_updated, _blocklist_id}, socket) do
    {:noreply,
     socket
     |> assign(blocklists: fetch_blocklists())
     |> assign(ram_usage: BlocklistLoader.get_memory_usage())
     |> assign(free_ram: BlocklistLoader.get_system_free_memory_string())}
  end

  # Helper functions
  defp fetch_blocklists do
    Hermit.Repo.all(from b in Blocklist, order_by: b.name)
  end

  defp assign_form(socket, struct \\ %Blocklist{}) do
    changeset = Blocklist.changeset(struct, %{})
    assign(socket, :form, to_form(changeset))
  end

  defp format_number(nil), do: "0"
  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_charlist()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.intersperse(~c",")
    |> List.flatten()
    |> Enum.reverse()
    |> List.to_string()
  end
end
