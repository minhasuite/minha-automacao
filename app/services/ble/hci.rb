require "socket"

module Ble
  # HCI cru do Linux (ondaC1, C2), Ruby puro (o bin/ble-scan usa sem Rails):
  # abre o adaptador (`hci0`), liga a varredura passiva (legada; se o
  # controlador recusar, a estendida do Bluetooth 5) e lê os relatórios de
  # anúncio (LE Meta 0x3E: 0x02 legado, 0x0D estendido) → [{mac, rssi, data}].
  # Precisa de rede do host e NET_ADMIN/NET_RAW (o serviço `ble-scanner`).
  module Hci
    AF_BLUETOOTH = 31
    BTPROTO_HCI = 1
    SOL_HCI = 0
    HCI_FILTER = 2
    COMMAND, EVENT = 0x01, 0x04
    LE_META, CMD_COMPLETE, CMD_STATUS = 0x3E, 0x0E, 0x0F
    LE = 0x08
    SET_SCAN_PARAMS, SET_SCAN_ENABLE = 0x000B, 0x000C
    SET_EXT_SCAN_PARAMS, SET_EXT_SCAN_ENABLE = 0x0041, 0x0042

    module_function

    def open(dev = 0)
      sock = Socket.new(AF_BLUETOOTH, Socket::SOCK_RAW, BTPROTO_HCI)
      sock.bind([ AF_BLUETOOTH, dev, 0 ].pack("SSS")) # sockaddr_hci: família, aparelho, canal cru
      # Filtro: só eventos (comando concluído/estado e LE Meta).
      sock.setsockopt(SOL_HCI, HCI_FILTER, [ 1 << EVENT, (1 << CMD_COMPLETE) | (1 << CMD_STATUS), 1 << (LE_META - 32), 0 ].pack("LLLS"))
      sock
    end

    def command(ocf, params, ogf: LE) = [ COMMAND, (ogf << 10) | ocf, params.bytesize ].pack("CvC") + params.b

    # Varredura passiva (sem pedir resposta aos aparelhos), sem filtro de repetidos.
    def legacy_scan(on)
      on ? [ command(SET_SCAN_PARAMS, [ 0, 0x0010, 0x0010, 0, 0 ].pack("CvvCC")), command(SET_SCAN_ENABLE, [ 1, 0 ].pack("CC")) ] : [ command(SET_SCAN_ENABLE, [ 0, 0 ].pack("CC")) ]
    end

    def extended_scan(on)
      return [ command(SET_EXT_SCAN_ENABLE, [ 0, 0, 0, 0 ].pack("CCvv")) ] unless on

      [ command(SET_EXT_SCAN_PARAMS, [ 0, 0, 0x01, 0, 0x0010, 0x0010 ].pack("CCCCvv")), command(SET_EXT_SCAN_ENABLE, [ 1, 0, 0, 0 ].pack("CCvv")) ]
    end

    # Estado do "comando concluído" (0 = ok) ou nil se o pacote não é a resposta deste comando.
    def command_status(packet, ocf)
      type, evt, _len = packet.unpack("CCC")
      return unless type == EVENT && evt == CMD_COMPLETE && packet.bytesize >= 7

      _n, opcode, status = packet.byteslice(3, 4).unpack("CvC")
      status if opcode == (LE << 10) | ocf
    end

    # Pacote de evento → anúncios [{"mac", "rssi", "data"}] (vazio se não é anúncio).
    def reports(packet)
      type, evt, _len, sub = packet.unpack("CCCC")
      return [] unless type == EVENT && evt == LE_META

      body = packet.byteslice(4..).to_s
      case sub
      when 0x02 then legacy_reports(body)
      when 0x0D then extended_reports(body)
      else []
      end
    end

    def legacy_reports(b)
      n, pos, out = b.getbyte(0).to_i, 1, []
      n.times do
        break if pos + 9 > b.bytesize

        addr = b.byteslice(pos + 2, 6)
        len = b.getbyte(pos + 8).to_i
        data = b.byteslice(pos + 9, len).to_s
        rssi = b.byteslice(pos + 9 + len, 1).to_s.unpack1("c")
        out << { "mac" => mac(addr), "rssi" => rssi, "data" => data }
        pos += 10 + len
      end
      out
    end

    def extended_reports(b)
      n, pos, out = b.getbyte(0).to_i, 1, []
      n.times do
        break if pos + 24 > b.bytesize

        addr = b.byteslice(pos + 3, 6)
        rssi = b.byteslice(pos + 13, 1).unpack1("c")
        len = b.getbyte(pos + 23).to_i
        out << { "mac" => mac(addr), "rssi" => rssi, "data" => b.byteslice(pos + 24, len).to_s }
        pos += 24 + len
      end
      out
    end

    # Endereço vem invertido no HCI.
    def mac(raw) = raw.bytes.reverse.map { |x| format("%02X", x) }.join(":")
  end
end
