defmodule Hermit.Vpn.Outbound do
  @doc """
  Khởi tạo card mạng và thiết lập Default Route trong namespace.
  """
  @callback bootstrap(
              pair_id :: String.t(),
              storage_dir :: String.t(),
              config :: map()
            ) :: {:ok, interface_name :: String.t()} | {:error, any()}

  @doc """
  Dọn dẹp card mạng và cấu hình liên quan khi dừng tunnel.
  """
  @callback cleanup(pair_id :: String.t(), storage_dir :: String.t()) :: :ok

  @doc """
  Lấy trạng thái kết nối từ hệ thống.
  """
  @callback get_status(pair_id :: String.t(), storage_dir :: String.t()) ::
              :running | :stopped | {:error, String.t()}

  @doc """
  Lấy lượng băng thông đã truyền nhận (bytes_sent, bytes_received).
  """
  @callback get_metrics(pair_id :: String.t(), storage_dir :: String.t()) ::
              {:ok, %{bytes_received: integer(), bytes_sent: integer()}} | :error
end
