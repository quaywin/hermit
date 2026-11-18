defmodule Hermit.Services.Catalog do
  @moduledoc """
  Defines the catalog of popular services (Streaming, AI, Social, Gaming)
  and their associated domain sets (including CDNs and static asset domains)
  for Smart DNS and transparent SNI proxy split tunneling.
  """

  @type service :: %{
          id: String.t(),
          name: String.t(),
          category: atom(),
          icon: String.t(),
          description: String.t(),
          domains: [String.t()]
        }

  @categories [
    %{id: :all, label: "All Services", icon: "hero-squares-2x2"},
    %{id: :streaming, label: "Streaming & Media", icon: "hero-film"},
    %{id: :ai, label: "AI & Cloud Tools", icon: "hero-sparkles"},
    %{id: :social, label: "Social & Chat", icon: "hero-chat-bubble-left-right"},
    %{id: :gaming, label: "Gaming", icon: "hero-puzzle-piece"}
  ]

  @services [
    # AI Services
    %{
      id: "openai",
      name: "OpenAI / ChatGPT",
      category: :ai,
      icon: "hero-sparkles",
      description: "ChatGPT web interface, API endpoints, authentication, and static CDN assets.",
      domains: [
        "*.openai.com",
        "*.chatgpt.com",
        "*.oaistatic.com",
        "*.oaiusercontent.com"
      ]
    },
    %{
      id: "claude",
      name: "Anthropic / Claude",
      category: :ai,
      icon: "hero-cpu-chip",
      description: "Claude.ai web console and Anthropic AI API services.",
      domains: [
        "*.anthropic.com",
        "*.claude.ai"
      ]
    },
    %{
      id: "gemini",
      name: "Google Gemini",
      category: :ai,
      icon: "hero-bolt",
      description: "Google Gemini web application and generative AI APIs.",
      domains: [
        "*.gemini.google.com",
        "*.bard.google.com",
        "*.generativeai.google"
      ]
    },
    %{
      id: "perplexity",
      name: "Perplexity AI",
      category: :ai,
      icon: "hero-magnifying-glass",
      description: "Perplexity AI search engine and answer services.",
      domains: [
        "*.perplexity.ai"
      ]
    },
    %{
      id: "midjourney",
      name: "Midjourney",
      category: :ai,
      icon: "hero-photo",
      description: "Midjourney website and image generation servers.",
      domains: [
        "*.midjourney.com"
      ]
    },
    %{
      id: "copilot",
      name: "Microsoft Copilot",
      category: :ai,
      icon: "hero-command-line",
      description: "Microsoft Copilot and GitHub Copilot API services.",
      domains: [
        "*.copilot.microsoft.com",
        "*.githubcopilot.com"
      ]
    },

    # Streaming Services
    %{
      id: "netflix",
      name: "Netflix",
      category: :streaming,
      icon: "hero-film",
      description: "Netflix streaming platform, video delivery network, and UI imagery.",
      domains: [
        "*.netflix.com",
        "*.netflix.net",
        "*.nflximg.net",
        "*.nflxvideo.net",
        "*.nflxext.com",
        "*.nflxso.net"
      ]
    },
    %{
      id: "youtube",
      name: "YouTube",
      category: :streaming,
      icon: "hero-play",
      description: "YouTube portal, Google Video streaming nodes, and thumbnail CDNs.",
      domains: [
        "*.youtube.com",
        "*.googlevideo.com",
        "*.ytimg.com",
        "*.youtu.be"
      ]
    },
    %{
      id: "bbc",
      name: "BBC iPlayer",
      category: :streaming,
      icon: "hero-tv",
      description: "BBC main portal, iPlayer streaming, and media distribution CDNs.",
      domains: [
        "*.bbc.co.uk",
        "*.bbci.co.uk",
        "*.bbc.com"
      ]
    },
    %{
      id: "disney",
      name: "Disney+",
      category: :streaming,
      icon: "hero-star",
      description: "Disney+, Star+, and DSS video delivery network.",
      domains: [
        "*.disneyplus.com",
        "*.disney-plus.net",
        "*.dssott.com",
        "*.bamgrid.com"
      ]
    },
    %{
      id: "hulu",
      name: "Hulu",
      category: :streaming,
      icon: "hero-video-camera",
      description: "Hulu streaming application and video CDN servers.",
      domains: [
        "*.hulu.com",
        "*.hulustream.com",
        "*.huluim.com"
      ]
    },
    %{
      id: "primevideo",
      name: "Amazon Prime Video",
      category: :streaming,
      icon: "hero-shopping-bag",
      description: "Prime Video catalogs, auth endpoints, and AWS media delivery CDNs.",
      domains: [
        "*.primevideo.com",
        "*.pv-cdn.net",
        "*.aiv-cdn.net",
        "*.media-amazon.com"
      ]
    },
    %{
      id: "max",
      name: "Max (HBO)",
      category: :streaming,
      icon: "hero-ticket",
      description: "Max / HBO Max streaming content and CDN distribution.",
      domains: [
        "*.max.com",
        "*.hbomax.com",
        "*.hbo.com"
      ]
    },
    %{
      id: "spotify",
      name: "Spotify",
      category: :streaming,
      icon: "hero-musical-note",
      description: "Spotify music streaming, artwork CDNs, and telemetry.",
      domains: [
        "*.spotify.com",
        "*.scdn.co",
        "*.spotifycdn.com"
      ]
    },
    %{
      id: "twitch",
      name: "Twitch",
      category: :streaming,
      icon: "hero-signal",
      description: "Twitch live streaming channels, video transcode feeds, and chat servers.",
      domains: [
        "*.twitch.tv",
        "*.ttvnw.net",
        "*.jtvnw.net"
      ]
    },

    # Social Services
    %{
      id: "tiktok",
      name: "TikTok",
      category: :social,
      icon: "hero-share",
      description: "TikTok app services, ByteDance CDNs, and media delivery.",
      domains: [
        "*.tiktok.com",
        "*.tiktokcdn.com",
        "*.tiktokv.com",
        "*.byteoversea.com",
        "*.ibytedtos.com"
      ]
    },
    %{
      id: "twitter",
      name: "Twitter / X",
      category: :social,
      icon: "hero-chat-bubble-left",
      description: "X (Twitter) web, API, link shortener, and image CDNs.",
      domains: [
        "*.twitter.com",
        "*.x.com",
        "*.twimg.com",
        "*.t.co"
      ]
    },
    %{
      id: "reddit",
      name: "Reddit",
      category: :social,
      icon: "hero-globe-alt",
      description: "Reddit forums, media upload servers, and static asset CDNs.",
      domains: [
        "*.reddit.com",
        "*.redd.it",
        "*.redditmedia.com",
        "*.redditstatic.com"
      ]
    },
    %{
      id: "discord",
      name: "Discord",
      category: :social,
      icon: "hero-user-group",
      description: "Discord gateway, voice/video connections, and asset CDN.",
      domains: [
        "*.discord.com",
        "*.discordapp.com",
        "*.discord.gg",
        "*.discordapp.net"
      ]
    },
    %{
      id: "telegram",
      name: "Telegram",
      category: :social,
      icon: "hero-paper-airplane",
      description: "Telegram web client, t.me links, and media clusters.",
      domains: [
        "*.telegram.org",
        "*.t.me",
        "*.telesco.pe"
      ]
    },

    # Gaming Services
    %{
      id: "steam",
      name: "Steam",
      category: :gaming,
      icon: "hero-puzzle-piece",
      description: "Valve Steam Store, Community hub, and content distribution nodes.",
      domains: [
        "*.steampowered.com",
        "*.steamcommunity.com",
        "*.steamstatic.com",
        "*.steamcontent.com"
      ]
    },
    %{
      id: "playstation",
      name: "PlayStation Network",
      category: :gaming,
      icon: "hero-device-phone-mobile",
      description: "Sony PlayStation Store and network services.",
      domains: [
        "*.playstation.com",
        "*.playstation.net",
        "*.sonyentertainmentnetwork.com"
      ]
    },
    %{
      id: "xbox",
      name: "Xbox Network",
      category: :gaming,
      icon: "hero-cube",
      description: "Microsoft Xbox Live authentication, telemetry, and CDN.",
      domains: [
        "*.xboxlive.com",
        "*.xbox.com"
      ]
    }
  ]

  @doc """
  Returns the complete list of supported services.
  """
  @spec all() :: [service()]
  def all, do: @services

  @doc """
  Returns the list of categories.
  """
  @spec categories() :: [map()]
  def categories, do: @categories

  @doc """
  Finds a service by its unique string id.
  """
  @spec get(String.t()) :: service() | nil
  def get(id) when is_binary(id) do
    Enum.find(@services, &(&1.id == id))
  end

  def get(_), do: nil

  @doc """
  Returns services belonging to a specific category.
  """
  @spec by_category(atom() | String.t()) :: [service()]
  def by_category(:all), do: @services
  def by_category("all"), do: @services

  def by_category(cat) when is_binary(cat) do
    try do
      by_category(String.to_existing_atom(cat))
    rescue
      ArgumentError -> []
    end
  end

  def by_category(cat) when is_atom(cat) do
    Enum.filter(@services, &(&1.category == cat))
  end

  @doc """
  Filters services by a search query (matches against name, id, or domain).
  """
  @spec search(String.t()) :: [service()]
  def search(query) when is_binary(query) do
    q = query |> String.trim() |> String.downcase()

    if q == "" do
      @services
    else
      Enum.filter(@services, fn svc ->
        String.contains?(String.downcase(svc.name), q) or
          String.contains?(svc.id, q) or
          Enum.any?(svc.domains, &String.contains?(&1, q))
      end)
    end
  end

  def search(_), do: @services

  @doc """
  Returns all domains associated with a given service ID.
  """
  @spec domains_for_service(String.t()) :: [String.t()]
  def domains_for_service(id) do
    case get(id) do
      nil -> []
      svc -> svc.domains
    end
  end
end
