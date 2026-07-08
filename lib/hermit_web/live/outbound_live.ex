defmodule HermitWeb.OutboundLive do
  use HermitWeb, :live_view
  import Ecto.Query
  alias Hermit.Vpn.OutboundProfile
  require Logger

  @impl true
  def mount(_params, _session, socket) do
    outbound_profiles = Hermit.Repo.all(OutboundProfile)

    {:ok,
     socket
     |> assign(outbound_profiles: outbound_profiles)
     |> assign(show_create_modal: false)
     |> assign(editing_outbound_profile: nil)
     |> assign(editing_outbound_form: nil)
     |> assign_outbound_form()}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("open_create_modal", _params, socket) do
    {:noreply, assign(socket, show_create_modal: true)}
  end

  @impl true
  def handle_event("close_create_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(show_create_modal: false)
     |> assign_outbound_form()}
  end

  @impl true
  def handle_event("validate_outbound", %{"outbound_profile" => params}, socket) do
    changeset =
      %OutboundProfile{}
      |> OutboundProfile.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, outbound_form: to_form(changeset))}
  end

  @impl true
  def handle_event("save_outbound", %{"outbound_profile" => params}, socket) do
    changeset = OutboundProfile.changeset(%OutboundProfile{}, params)

    case Hermit.Repo.insert(changeset) do
      {:ok, _profile} ->
        outbound_profiles = Hermit.Repo.all(OutboundProfile)

        {:noreply,
         socket
         |> put_flash(:info, "Outbound Profile created successfully.")
         |> assign(outbound_profiles: outbound_profiles)
         |> assign(show_create_modal: false)
         |> assign_outbound_form()}

      {:error, changeset} ->
        {:noreply, assign(socket, outbound_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("edit_outbound", %{"id" => id}, socket) do
    profile = Hermit.Repo.get!(OutboundProfile, id)
    changeset = OutboundProfile.changeset(profile, %{})

    {:noreply,
     socket
     |> assign(editing_outbound_profile: profile)
     |> assign(editing_outbound_form: to_form(changeset))}
  end

  @impl true
  def handle_event("close_edit_outbound", _params, socket) do
    {:noreply,
     socket
     |> assign(editing_outbound_profile: nil)
     |> assign(editing_outbound_form: nil)}
  end

  @impl true
  def handle_event("validate_edit_outbound", %{"outbound_profile" => params}, socket) do
    profile = socket.assigns.editing_outbound_profile

    changeset =
      profile
      |> OutboundProfile.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, editing_outbound_form: to_form(changeset))}
  end

  @impl true
  def handle_event("save_edit_outbound", %{"outbound_profile" => params}, socket) do
    profile = socket.assigns.editing_outbound_profile
    changeset = OutboundProfile.changeset(profile, params)

    case Hermit.Repo.update(changeset) do
      {:ok, _profile} ->
        outbound_profiles = Hermit.Repo.all(OutboundProfile)

        {:noreply,
         socket
         |> put_flash(:info, "Outbound Profile updated successfully.")
         |> assign(outbound_profiles: outbound_profiles)
         |> assign(editing_outbound_profile: nil)
         |> assign(editing_outbound_form: nil)}

      {:error, changeset} ->
        {:noreply, assign(socket, editing_outbound_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_outbound", %{"id" => id}, socket) do
    profile = Hermit.Repo.get!(OutboundProfile, id)

    active_referencing_tunnels =
      Hermit.Repo.all(
        from(p in Hermit.Vpn.VpnPair,
          where: p.outbound_profile_id == ^profile.id
        )
      )

    if active_referencing_tunnels != [] do
      {:noreply,
       put_flash(socket, :error, "Cannot delete profile because it is in use by active tunnels.")}
    else
      case Hermit.Repo.delete(profile) do
        {:ok, _} ->
          outbound_profiles = Hermit.Repo.all(OutboundProfile)

          {:noreply,
           socket
           |> put_flash(:info, "Outbound Profile deleted.")
           |> assign(outbound_profiles: outbound_profiles)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete profile.")}
      end
    end
  end

  # --- Helpers ---

  defp assign_outbound_form(socket) do
    changeset = OutboundProfile.changeset(%OutboundProfile{type: "wireguard"}, %{})
    assign(socket, outbound_form: to_form(changeset))
  end
end
