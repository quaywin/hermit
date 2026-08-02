defmodule HermitWeb.InboundDetailLive do
  use HermitWeb, :live_view
  import Ecto.Query
  alias Hermit.Vpn.InboundProfile
  alias Hermit.Vpn.DnsWorker
  require Logger

  @impl true
  def mount(%{"id" => id_str}, _session, socket) do
    id = String.to_integer(id_str)

    case Hermit.Repo.get(InboundProfile, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Inbound Profile '#{id}' not found.")
         |> push_navigate(to: ~p"/inbounds")}

      profile ->
        # Subscription for status polling if needed
        if connected?(socket) and profile.type == "tailscale" do
          :timer.send_interval(1000, self(), :tick)
        end

        changeset = InboundProfile.changeset(profile, %{})

        {:ok,
         socket
         |> assign(id: id)
         |> assign(profile: profile)
         |> assign(vpn_pairs: [])
         |> assign(editing_inbound_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    active_tab =
      case Map.get(params, "tab", "config") do
        "routing" when socket.assigns.profile.type == "tailscale" -> :routing
        _ -> :config
      end

    socket =
      if active_tab == :routing do
        reload_routing_tab(socket)
      else
        socket
      end

    {:noreply, assign(socket, active_tab: active_tab)}
  end

  @impl true
  def handle_event("validate_edit_inbound", %{"inbound_profile" => params}, socket) do
    profile = socket.assigns.profile

    changeset =
      profile
      |> InboundProfile.changeset(params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, editing_inbound_form: to_form(changeset))}
  end

  @impl true
  def handle_event("save_edit_inbound", %{"inbound_profile" => params}, socket) do
    profile = socket.assigns.profile
    changeset = InboundProfile.changeset(profile, params)

    case Hermit.Repo.update(changeset) do
      {:ok, updated_profile} ->
        InboundProfile.clear_cache()

        # Reboot all active DNS endpoints linked to this Inbound Profile if credentials changed
        reboot_linked_dns_endpoints(updated_profile.id)

        reloaded_profile = Hermit.Repo.get!(InboundProfile, updated_profile.id)
        changeset_new = InboundProfile.changeset(reloaded_profile, %{})

        {:noreply,
         socket
         |> put_flash(:info, "Inbound Profile updated successfully.")
         |> assign(profile: reloaded_profile)
         |> assign(editing_inbound_form: to_form(changeset_new))}

      {:error, changeset} ->
        {:noreply, assign(socket, editing_inbound_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_inbound", _params, socket) do
    profile = socket.assigns.profile

    active_referencing_tunnels =
      Hermit.Repo.all(
        from(p in Hermit.Vpn.VpnPair,
          where: p.inbound_profile_id == ^profile.id
        )
      )

    if active_referencing_tunnels != [] do
      {:noreply,
       put_flash(socket, :error, "Cannot delete profile because it is in use by active tunnels.")}
    else
      # Dừng tất cả các DNS Endpoints đang sử dụng Inbound Profile này
      endpoints =
        Hermit.Repo.all(
          from(e in Hermit.Vpn.DnsEndpoint, where: e.inbound_profile_id == ^profile.id)
        )

      Enum.each(endpoints, fn endpoint ->
        config = Hermit.Vpn.DnsConfig.get_for_endpoint(endpoint.id)

        if config && config.tailscale_override_dns do
          Task.start(fn -> DnsWorker.clear_tailscale_dns_config(config) end)
        end

        Hermit.Vpn.DnsSupervisor.stop_dns(endpoint.id)

        endpoint
        |> Hermit.Vpn.DnsEndpoint.changeset(%{inbound_profile_id: nil, enabled: false})
        |> Hermit.Repo.update!()
      end)

      case Hermit.Repo.delete(profile) do
        {:ok, _} ->
          InboundProfile.clear_cache()
          Hermit.Vpn.DnsEndpoint.clear_cache()

          {:noreply,
           socket
           |> put_flash(:info, "Inbound Profile deleted.")
           |> push_navigate(to: ~p"/inbounds")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete profile.")}
      end
    end
  end

  @impl true
  def handle_event("delete_domain", %{"pair-id" => pair_id_or_tag, "domain" => domain}, socket) do
    case Hermit.Repo.get(Hermit.Vpn.VpnPair, pair_id_or_tag) do
      nil ->
        if String.starts_with?(pair_id_or_tag, "tag:") do
          profile = socket.assigns.profile

          case Hermit.Vpn.Inbound.Tailscale.get_app_connectors(profile) do
            {:ok, list} ->
              connector =
                Enum.find(list, fn conn -> pair_id_or_tag in Map.get(conn, "connectors", []) end)

              if connector do
                existing_domains = Map.get(connector, "domains", [])
                updated_domains = Enum.reject(existing_domains, &(&1 == domain))

                case Hermit.Vpn.Inbound.Tailscale.update_profile_connector_acl(
                       profile,
                       pair_id_or_tag,
                       updated_domains
                     ) do
                  {:ok, _} ->
                    socket = reload_routing_tab(socket)

                    {:noreply,
                     put_flash(
                       socket,
                       :info,
                       "Domain #{domain} removed from external node #{pair_id_or_tag}. ACL updated."
                     )}

                  {:error, reason} ->
                    {:noreply,
                     put_flash(
                       socket,
                       :error,
                       "Failed to update Tailscale ACL: #{inspect(reason)}"
                     )}
                end
              else
                {:noreply, socket}
              end

            _ ->
              {:noreply, socket}
          end
        else
          {:noreply, socket}
        end

      _pair ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("tick", _params, socket) do
    {:noreply, reload_routing_tab(socket)}
  end

  # Helper functions

  defp reload_routing_tab(socket) do
    profile = socket.assigns.profile
    profile_id = profile.id
    # Fetch active tunnels utilizing this inbound profile
    pairs_db =
      Hermit.Repo.all(
        from(p in Hermit.Vpn.VpnPair,
          where: p.inbound_profile_id == ^profile_id,
          order_by: [asc: p.pair_id]
        )
      )

    hermit_tags =
      Enum.reduce(pairs_db, MapSet.new(), fn p, acc ->
        tag =
          p.inbound_config["advertise_connector_tag"] ||
            "tag:connector-" <> String.replace(p.pair_id, "_", "-")

        MapSet.put(acc, tag)
      end)

    external_connectors =
      case Hermit.Vpn.Inbound.Tailscale.get_app_connectors(profile) do
        {:ok, list} ->
          list
          |> Enum.filter(fn conn ->
            tag = Enum.at(conn["connectors"] || [], 0)
            tag && not MapSet.member?(hermit_tags, tag)
          end)
          |> Enum.map(fn conn ->
            tag = Enum.at(conn["connectors"], 0)

            %{
              id: tag,
              name: conn["name"] || tag,
              is_external: true,
              inbound_config: %{
                "advertise_connector" => true,
                "advertise_connector_tag" => tag,
                "advertise_connector_domains" => Enum.join(conn["domains"] || [], "\n"),
                "advertise_routes" => ""
              },
              wg_status: :external,
              ts_status: :external
            }
          end)

        _ ->
          []
      end

    hermit_pairs =
      Enum.map(pairs_db, fn pair ->
        case Hermit.Vpn.PairWorker.get_state(pair.pair_id) do
          {:error, _} ->
            %{
              id: pair.pair_id,
              is_external: false,
              wg_status: String.to_atom(pair.wg_status || "stopped"),
              ts_status: String.to_atom(pair.ts_status || "stopped"),
              inbound_config: pair.inbound_config || %{}
            }

          worker_state ->
            %{
              id: worker_state.id,
              is_external: false,
              wg_status: worker_state.wg_status,
              ts_status: worker_state.ts_status,
              inbound_config: worker_state.inbound_config || %{}
            }
        end
      end)

    assign(socket, vpn_pairs: hermit_pairs ++ external_connectors)
  end

  defp parse_domains(domains_str) do
    if is_binary(domains_str) do
      domains_str
      |> String.split([",", "\n"])
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
    else
      []
    end
  end

  defp reboot_linked_dns_endpoints(inbound_profile_id) do
    # Find all DNS endpoints using this Inbound Profile
    endpoints =
      Hermit.Repo.all(
        from(e in Hermit.Vpn.DnsEndpoint, where: e.inbound_profile_id == ^inbound_profile_id)
      )

    Enum.each(endpoints, fn endpoint ->
      {status, _, _} = DnsWorker.get_status(endpoint.id)

      if status == :running do
        Hermit.Vpn.DnsSupervisor.stop_dns(endpoint.id)

        if endpoint.enabled do
          Hermit.Vpn.DnsSupervisor.start_dns(endpoint.id, inbound_profile_id)
        end
      end
    end)
  end
end
