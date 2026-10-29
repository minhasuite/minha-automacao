# Nascer e pôr do sol (algoritmo do Almanac for Computers, zênite oficial
# 90,833°: erro de 1 a 2 minutos, suficiente para acender luz).
# `Sun.at("sunset", data_local, lat, lng, zona)` → Time em UTC, ou nil quando
# o sol não nasce/não se põe nesse dia (círculo polar).
module Sun
  ZENITH = 90.833

  module_function

  def at(event, date, lat, lng, zone)
    rise = event == "sunrise"
    lng_hour = lng.to_f / 15
    t = date.yday + (((rise ? 6 : 18) - lng_hour) / 24)
    m = (0.9856 * t) - 3.289
    l = (m + (1.916 * sin(m)) + (0.020 * sin(2 * m)) + 282.634) % 360
    ra = deg(Math.atan(0.91764 * tan(l))) % 360
    ra = (ra + ((l / 90).floor * 90) - ((ra / 90).floor * 90)) / 15
    sin_dec = 0.39782 * sin(l)
    cos_dec = Math.cos(Math.asin(sin_dec))
    cos_h = (cos(ZENITH) - (sin_dec * sin(lat.to_f))) / (cos_dec * cos(lat.to_f))
    return if cos_h.abs > 1

    h = (rise ? 360 - deg(Math.acos(cos_h)) : deg(Math.acos(cos_h))) / 15
    ut = (h + ra - (0.06571 * t) - 6.622 - lng_hour) % 24
    time = Time.utc(date.year, date.month, date.day) + (ut * 3600).round
    # O horário em UTC pode cair no dia vizinho do dia local.
    local = time.in_time_zone(zone).to_date
    time + (date - local).to_i.days
  end

  def sin(d) = Math.sin(d * Math::PI / 180)
  def cos(d) = Math.cos(d * Math::PI / 180)
  def tan(d) = Math.tan(d * Math::PI / 180)
  def deg(r) = r * 180 / Math::PI
end
