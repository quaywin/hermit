defmodule HermitWeb.DnsEndpointComponents do
  @moduledoc """
  Functional components for the Tailscale DNS Endpoints LiveView.
  """
  use HermitWeb, :html

  attr :endpoint, :map, required: true
  attr :dns_status, :any, required: true
  attr :dns_profiles, :list, required: true

  def endpoint_row(assigns) do
    {status, ip, err} = assigns.dns_status
    config = assigns.endpoint.dns_profile

    assigns =
      assigns
      |> assign(:status, status)
      |> assign(:ip, ip)
      |> assign(:err, err)
      |> assign(:config, config)

    ~H"""
    <tr class="hover:bg-base-200/50 transition-colors">
      <!-- 1. Endpoint Name -->
      <td class="py-4 px-4 font-medium text-base-content">
        <div class="flex items-center gap-2">
          <span class="text-base">🌐</span>
          <span class="font-bold text-base-content">{@endpoint.name}</span>
        </div>
        <span class="block text-[10px] font-mono text-base-content/50 mt-0.5">
          hermit-dns-{@endpoint.id}
        </span>
      </td>

      <!-- 2. Tailscale Inbound -->
      <td class="py-4 px-4">
        <%= if @endpoint.inbound_profile_id do %>
          <span class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-medium bg-[#ff7e47]/10 text-[#ff7e47] border border-[#ff7e47]/20">
            Tailscale Connection
          </span>
          <span class="block text-[10px] text-base-content/50 font-mono mt-0.5">
            {if @endpoint.inbound_profile,
              do: @endpoint.inbound_profile.name,
              else: "Profile ##{@endpoint.inbound_profile_id}"}
          </span>
        <% else %>
          <span class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-medium bg-base-200 text-base-content/60 border border-base-300">
            Unassigned
          </span>
        <% end %>
      </td>

      <!-- 3. DNS Profile -->
      <td class="py-4 px-4">
        <div class="flex items-center gap-1.5">
          <form
            phx-change="quick_select_dns_profile"
            id={"quick-select-dns-form-#{@endpoint.id}"}
            class="inline-block"
          >
            <input type="hidden" name="endpoint_id" value={@endpoint.id} />
            <select
              name="dns_profile_id"
              class="select select-bordered select-xs bg-base-100 border-base-300 text-xs font-semibold text-base-content rounded-[4px] focus:outline-none focus:border-primary"
            >
              <%= for profile <- @dns_profiles do %>
                <option value={profile.id} selected={@endpoint.dns_profile_id == profile.id}>
                  🛡️ {profile.name}
                </option>
              <% end %>
            </select>
          </form>
          <%= if @endpoint.dns_profile_id do %>
            <.link
              navigate={~p"/dns"}
              class="btn btn-ghost btn-xs text-base-content/40 hover:text-emerald-500 p-1"
              title="Configure Profile Rules & Filters"
            >
              <.icon name="hero-cog-6-tooth" class="size-3.5" />
            </.link>
          <% end %>
        </div>
      </td>

      <!-- 4. Node State -->
      <td class="py-4 px-4">
        <div class="space-y-1">
          <div>
            <%= case @status do %>
              <% :running -> %>
                <span class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-medium bg-emerald-500/10 text-emerald-500 border border-emerald-500/20">
                  <span class="w-1.5 h-1.5 rounded-full bg-emerald-500 animate-pulse"></span>
                  running
                </span>
              <% :starting -> %>
                <span class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-medium bg-amber-500/10 text-amber-500 border border-amber-500/20">
                  <span class="w-1.5 h-1.5 rounded-full bg-amber-500 animate-bounce"></span>
                  starting
                </span>
              <% :error -> %>
                <span
                  class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-medium bg-red-500/10 text-red-500 border border-red-500/20 cursor-help"
                  title={@err}
                >
                  <span class="w-1.5 h-1.5 rounded-full bg-red-500"></span> error
                </span>
              <% :stopped -> %>
                <span class="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full text-xs font-medium bg-base-200 text-base-content/60 border border-base-300">
                  <span class="w-1.5 h-1.5 rounded-full bg-base-content/40"></span> stopped
                </span>
            <% end %>
          </div>
          <%= if @ip do %>
            <div class="flex items-center gap-1">
              <span class="text-[11px] font-mono text-base-content/70 select-all">{@ip}</span>
              <.copy_button
                text={@ip}
                title="Copy Tailscale DNS IP"
                class="border-0 !p-0.5 !bg-transparent text-base-content/40 hover:text-emerald-500"
              />
            </div>
          <% end %>
          <%= if @config && @config.tailscale_override_dns do %>
            <span class="inline-block px-1.5 py-0.5 rounded text-[10px] font-semibold bg-emerald-500/15 text-emerald-600 border border-emerald-500/20">
              HA Global DNS
            </span>
          <% end %>
        </div>
      </td>

      <!-- 5. Actions -->
      <td class="py-4 px-4 text-right">
        <div class="flex items-center justify-end gap-2">
          <%= if @endpoint.inbound_profile_id do %>
            <button
              phx-click="toggle_override_dns"
              phx-value-id={@endpoint.id}
              disabled={@status != :running}
              class={[
                "btn btn-xs rounded-[4px] cursor-pointer font-medium text-[11px] px-2",
                @config && @config.tailscale_override_dns && "btn-success text-white",
                !(@config && @config.tailscale_override_dns) &&
                  "btn-outline-custom text-base-content/70",
                @status != :running && "opacity-40 cursor-not-allowed"
              ]}
              title={
                if @config && @config.tailscale_override_dns,
                  do: "Tailscale Global DNS: ON (Click to disable)",
                  else: "Tailscale Global DNS: OFF (Click to enable)"
              }
            >
              Global DNS
            </button>
          <% end %>

          <button
            type="button"
            phx-click="toggle_endpoint_enabled"
            phx-value-id={@endpoint.id}
            disabled={is_nil(@endpoint.inbound_profile_id)}
            class={[
              "btn btn-xs rounded-[4px] cursor-pointer font-medium text-xs px-2.5",
              @endpoint.enabled && "btn-success btn-outline",
              !@endpoint.enabled && "btn-ghost border border-base-300 text-base-content/60",
              is_nil(@endpoint.inbound_profile_id) && "opacity-40 cursor-not-allowed"
            ]}
            title={
              cond do
                is_nil(@endpoint.inbound_profile_id) -> "Assign a Tailscale Inbound Profile to activate"
                @endpoint.enabled -> "Click to Deactivate"
                true -> "Click to Activate"
              end
            }
          >
            {if @endpoint.enabled, do: "Active", else: "Disabled"}
          </button>

          <button
            phx-click="edit_endpoint"
            phx-value-id={@endpoint.id}
            class="btn btn-xs btn-outline-custom rounded-[4px] cursor-pointer font-medium text-xs px-2"
            title="Edit Endpoint Settings"
          >
            <.icon name="hero-pencil-square" class="size-3.5" />
          </button>

          <button
            phx-click="delete_endpoint"
            phx-value-id={@endpoint.id}
            data-confirm="Are you sure you want to permanently delete this DNS Endpoint?"
            class="btn btn-xs btn-error btn-outline rounded-[4px] cursor-pointer font-medium text-xs px-2"
            title="Delete Endpoint"
          >
            <.icon name="hero-trash" class="size-3.5" />
          </button>
        </div>
      </td>
    </tr>
    """
  end

  attr :mode, :atom, values: [:create, :edit], required: true
  attr :form, :any, required: true
  attr :dns_profiles, :list, required: true
  attr :inbound_profiles, :list, required: true

  def endpoint_form_modal(assigns) do
    is_create = assigns.mode == :create

    assigns =
      assigns
      |> assign(
        :dialog_id,
        if(is_create, do: "create-endpoint-modal", else: "edit-endpoint-modal")
      )
      |> assign(:form_id, if(is_create, do: "create-endpoint-form", else: "edit-endpoint-form"))
      |> assign(:title, if(is_create, do: "🔌 Create DNS Endpoint", else: "✏️ Edit DNS Endpoint"))
      |> assign(:close_event, if(is_create, do: "close_new_modal", else: "close_edit_modal"))
      |> assign(:validate_event, if(is_create, do: "validate_new", else: "validate_edit"))
      |> assign(:submit_event, if(is_create, do: "save_new", else: "save_edit"))
      |> assign(:submit_label, if(is_create, do: "Create Endpoint", else: "Save Changes"))
      |> assign(
        :name_placeholder,
        if(is_create, do: "e.g., Home Tailnet DNS, Office Tailnet", else: nil)
      )

    ~H"""
    <dialog id={@dialog_id} class="modal modal-open z-50 backdrop-blur-sm">
      <div class="modal-box w-full max-w-lg bg-base-100 border border-base-300 p-6 space-y-4 text-base-content rounded-[16px]">
        <div class="flex items-center justify-between border-b border-base-300 pb-3">
          <h3 class="text-lg font-medium text-base-content flex items-center gap-2">
            {@title}
          </h3>
          <button
            type="button"
            phx-click={@close_event}
            class="text-base-content/60 hover:text-base-content transition-colors cursor-pointer"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <.form
          :let={f}
          for={@form}
          phx-change={@validate_event}
          phx-submit={@submit_event}
          id={@form_id}
          class="space-y-4"
        >
          <div class="space-y-1.5">
            <label class="block text-xs font-medium uppercase tracking-wider text-base-content/60">
              Endpoint Name
            </label>
            <.input
              field={f[:name]}
              type="text"
              placeholder={@name_placeholder}
              class="w-full input input-bordered bg-base-100 border-base-300 focus:border-[#3ecf8e] text-base-content text-sm rounded-[4px]"
            />
          </div>

          <div class="space-y-1.5">
            <label class="block text-xs font-medium uppercase tracking-wider text-base-content/60">
              DNS Filtering Profile
            </label>
            <.input
              field={f[:dns_profile_id]}
              type="select"
              prompt="-- Choose Profile --"
              options={Enum.map(@dns_profiles, &{&1.name, &1.id})}
              class="w-full select select-bordered bg-base-100 border-base-300 focus:border-[#3ecf8e] text-base-content text-sm rounded-[4px]"
            />
          </div>

          <div class="space-y-1.5">
            <label class="block text-xs font-medium uppercase tracking-wider text-base-content/60">
              Tailscale Inbound Profile <span class="text-error">*</span>
            </label>
            <.input
              field={f[:inbound_profile_id]}
              type="select"
              prompt="-- Select Tailscale Inbound --"
              options={Enum.map(@inbound_profiles, &{&1.name, &1.id})}
              required
              class="w-full select select-bordered bg-base-100 border-base-300 focus:border-[#3ecf8e] text-base-content text-sm rounded-[4px]"
            />
          </div>

          <div class="flex items-center justify-end gap-2 pt-4 border-t border-base-300">
            <button
              type="button"
              phx-click={@close_event}
              class="btn btn-outline-custom rounded-[6px] text-xs uppercase tracking-wider px-4 py-2 cursor-pointer"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="btn btn-primary rounded-[6px] text-xs uppercase tracking-wider px-4 py-2 cursor-pointer text-white font-semibold"
            >
              {@submit_label}
            </button>
          </div>
        </.form>
      </div>
    </dialog>
    """
  end
end
