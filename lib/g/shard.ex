defmodule G.Shard do
  use WebSockex
  require Logger

  @api_base "https://discordapp.com/api/v6"

  @large_threshold 250
  @gateway_url "wss://gateway.discord.gg/?v=6&encoding=etf"

  ##################
  ## Opcode stuff ##
  ##################

  @op_dispatch              0   # Recv.
  @op_heartbeat             1   # Send/Recv.
  @op_identify              2   # Send
  @op_status_update         3   # Send
  @op_voice_state_update    4   # Send
  @op_voice_server_ping     5   # Send
  @op_resume                6   # Send
  @op_reconnect             7   # Recv.
  @op_request_guild_members 8   # Send
  @op_invalid_session       9   # Recv.
  @op_hello                 10  # Recv.
  @op_heartbeat_ack         11  # Recv.

  # Lookup table for translation
  @opcodes %{
    @op_dispatch              => :dispatch,
    @op_heartbeat             => :heartbeat,
    @op_identify              => :identify,
    @op_status_update         => :status_update,
    @op_voice_state_update    => :voice_state_update,
    @op_voice_server_ping     => :voice_server_ping,
    @op_resume                => :resume,
    @op_reconnect             => :reconnect,
    @op_request_guild_members => :request_guild_members,
    @op_invalid_session       => :invalid_session,
    @op_hello                 => :hello,
    @op_heartbeat_ack         => :heartbeat_ack
  }

  #############
  ## UTILITY ##
  #############

  defp info(state, message) do
    Logger.info "[SHARD #{state[:shard_id]}/#{state[:shard_count]}] #{message}"
  end
  defp warn(state, message) do
    Logger.warn "[SHARD #{state[:shard_id]}/#{state[:shard_count]}] #{message}"
  end

  ###############
  ## WEBSOCKET ##
  ###############

  def start_link(state) do
    unless state[:shard_id] >= state[:shard_count] do
      state |> info("Connecting to gateway #{@gateway_url}")
      internal_id = HTTPoison.get!(System.get_env("RAINDROP_URL")).body
      state = state
              |> Map.put(:internal_id, internal_id)
              |> Map.put(:seq, 0)
              |> Map.put(:trace, [])
      {:ok, state}
    else
      {:error, "invalid shard count: #{state[:shard_id]} >= #{state[:shard_count]}"}
    end
  end

  def init(state) do
    Logger.info "[SHARD] init?"
    {:ok, state}
  end

  def handle_connect(conn, state) do
    Logger.info "[DISCORD] Connected to gateway"
    unless is_nil state[:session_id] do
      Logger.info "[DISCORD] We have a session; expect OP 10 -> OP 6."
    end
    headers = Enum.into conn.resp_headers, %{}
    ray = headers["Cf-Ray"]
    server = headers[:Server]
    Logger.info "[DISCORD] Connected to #{server} ray #{ray}"
    new_state = state
                |> Map.put(:client_pid, self())
                |> Map.put(:cf_ray, ray)
                |> Map.put(:trace, nil)
    # We connected to the gateway successfully, we're logging in now
    send state[:parent], {:shard_status, :logging_in}
    {:ok, new_state}
  end

  def handle_frame({:binary, msg}, state) do
    payload = :erlang.binary_to_term(msg)
    # When we get a gateway op, it'll be of the same form always, which makes our lives easier
    state |> info("Got gateway message: #{inspect payload, pretty: true}")
    state = state |> Map.put(:seq, payload[:s] || state[:seq])
    {res, reply, new_state} = handle_op payload[:op], payload, state
    case res do
      :reply -> {:reply, reply, new_state}
      :noreply -> {:ok, new_state}
      # Just immediately die
      :terminate -> {:close, new_state}
    end
  end

  def handle_frame(msg, state) do
    Logger.info "[DISCORD] Got gateway payload: #{inspect msg}"
    {:ok, state}
  end

  def handle_disconnect(disconnect_map, state) do
    state |> warn("[DISCORD] Disconnected from websocket!")
    unless is_nil disconnect_map[:reason] do
      state |> warn("[DISCORD] Disconnect reason: #{inspect disconnect_map[:reason]}")
    end
    state |> warn("[DISCORD] Done! Please start a new gateway link.")
    # Disconnected from gateway, so not much else to say here
    {:ok, state}
  end

  def terminate(reason, _state) do
    Logger.info "[DISCORD] Websocket terminating: #{inspect reason}"
    :ok
  end

  ######################
  ## GATEWAY HANDLERS ##
  ######################

  defp handle_op(@op_hello, payload, state) do
    d = payload[:d]
    state |> info("Hello!")
    # Start HEARTBEAT once we get HELLO
    send self(), {:heartbeat, d[:heartbeat_interval]}
    state |> info("Trace: #{inspect d[:trace], pretty: true}")
    # Alert the cluster that we finished booting, backing off a bit to allow
    # for proper IDENTIFY ratelimit handling
    Process.send_after state[:cluster], :shard_booted, 5500
    # Finally, fire off an IDENTIFY
    {:reply, identify(state), %{state | trace: d[:trace]}}
  end

  #######################
  ## GATEWAY LIFECYCLE ##
  #######################

  def handle_info({:heartbeat, interval} = message, state) do
    payload = binary_payload @op_heartbeat, state[:seq]
    WebSockex.send_frame self(), {:binary, payload}
    Process.send_after self(), message, interval
    {:ok, state}
  end

  #####################
  ## GATEWAY HELPERS ##
  #####################

  defp identify(state) do
    state |> info("[DISCORD] Identifying as [#{inspect state[:shard_id]}, #{inspect state[:shard_count]}]...")
    data = %{
      "token" => state[:token],
      "properties" => %{
        "$os" => "BEAM",
        "$browser" => "samantha",
        "$device" => "samantha"
      },
      "compress" => false,
      "large_threshold" => @large_threshold,
      "shard" => [state[:shard_id], state[:shard_count]],
    }
    payload = binary_payload @op_identify, data
    Logger.info "[DISCORD] Done!"
    {:binary, payload}
  end

  defp resume(state) do
    seq = GenServer.call state[:parent], :seq
    state |> info("[DISCORD] Resuming from seq #{inspect seq}")
    payload = binary_payload @op_resume, %{
      "session_id" => state[:session_id],
      "token" => state[:token],
      "seq" => seq,
      "properties" => %{
        "$os" => "BEAM",
        "$browser" => "samantha",
        "$device" => "samantha"
      },
      "compress" => false,
      "shard" => [state[:shard_id], state[:shard_count]],
    }
    {:binary, payload}
  end

  def binary_payload(op, data, seq_num \\ nil, event_name \\ nil) do
    payload_base(op, data, seq_num, event_name)
    |> :erlang.term_to_binary
  end

  def payload_base(op, data, seq_num, event_name) do
    payload = %{"op" => op, "d" => data}
    payload
    |> update_payload(seq_num, "s", seq_num)
    |> update_payload(event_name, "t", seq_num)
  end

  defp update_payload(payload, var, key, value) do
    if var do
      Map.put(payload, key, value)
    else
      payload
    end
  end
end