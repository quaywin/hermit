defmodule Hermit.Vpn.Inbound do
  @doc """
  Khởi động tiến trình daemon và kết nối mạng đầu vào bên trong namespace.
  """
  @callback bootstrap(
              pair_id :: String.t(),
              outbound_if :: String.t(),
              storage_dir :: String.t(),
              config :: map()
            ) :: {:ok, port_or_pid :: port() | pid()} | {:error, any()}

  @doc """
  Dừng tiến trình daemon và dọn dẹp tài nguyên.
  """
  @callback cleanup(pair_id :: String.t(), storage_dir :: String.t()) :: :ok

  @doc """
  Lấy trạng thái hoạt động của Inbound.
  """
  @callback get_status(pair_id :: String.t(), storage_dir :: String.t()) ::
              :running | :stopped | {:error, String.t()}

  @doc """
  Lấy thông tin mạng (IP ảo, DNS ảo, User đăng nhập...) từ bên trong namespace.
  """
  @callback get_network_info(pair_id :: String.t(), storage_dir :: String.t()) :: map()

  @doc """
  Cập nhật cấu hình động cho Inbound khi đang chạy.
  """
  @callback update_settings(pair_id :: String.t(), config :: map()) ::
              :ok | {:ok, any()} | {:error, any()}

  @doc """
  Phê duyệt các route quảng bá của node (ví dụ: exit node, subnet).
  """
  @callback approve_exit_node(pair_id :: String.t()) ::
              :ok | {:ok, any()} | {:error, any()}
end
