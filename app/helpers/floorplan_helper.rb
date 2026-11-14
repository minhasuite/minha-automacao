# Planta baixa (widget floorplan e o editor dela): desenho de domínio montado só com utilitários do Tailwind,
# tokens da gem e o movimento da gem (keyframes ss-a-*, paradas com "menos movimento"). Sem CSS próprio.
# O <div> da planta é o `group/fp`; o modo noite é o data-night dele (floorplan_controller). A cor real da
# lâmpada vem em --glow (inline); sem ela, o âmbar do --warn. Classes por extenso (sem interpolação): o
# Tailwind só gera o que lê inteiro no código.
module FloorplanHelper
  FP_ROOT = "group/fp motion-reduce:[&_*]:transition-none".freeze
  FP_STAGE = "relative overflow-hidden rounded-[14px] bg-field isolate @container " \
             "[&.is-drawn]:aspect-[16/10] [&.is-drawn]:bg-[radial-gradient(circle,color-mix(in_srgb,var(--muted)_22%,transparent)_1px,transparent_1.5px)] " \
             "[&.is-drawn]:bg-[length:18px_18px] group-data-[night]/fp:bg-[color-mix(in_srgb,var(--side)_80%,black)]".freeze
  # Esqueleto enquanto a imagem carrega (o controller marca data-loaded).
  FP_LOADING = "has-[>img:not([data-loaded])]:bg-[linear-gradient(100deg,var(--field)_40%,color-mix(in_srgb,var(--surface)_65%,var(--field))_50%,var(--field)_60%)] " \
               "has-[>img:not([data-loaded])]:bg-[length:300%_100%] has-[>img:not([data-loaded])]:animate-[ss-a-shimmer_1.4s_linear_infinite] " \
               "motion-reduce:animate-none".freeze
  FP_IMG = "dw-fp-img block w-full h-auto select-none [-webkit-user-drag:none] transition-[filter] duration-[.6s] [&[hidden]]:hidden " \
           "group-data-[night]/fp:[filter:brightness(.32)_saturate(.5)_contrast(1.1)]".freeze
  FP_ROOM = "absolute flex items-start py-[.35rem] px-2 rounded-[10px] no-underline border-[1.5px] " \
            "border-[color-mix(in_srgb,var(--accent)_35%,transparent)] bg-[color-mix(in_srgb,var(--accent)_6%,transparent)] " \
            "transition-[background-color,border-color,box-shadow] duration-[.4s] hover:border-accent hover:bg-[color-mix(in_srgb,var(--accent)_12%,transparent)] " \
            "in-[.is-drawn]:bg-surface in-[.is-drawn]:border-line in-[.is-drawn]:shadow-[var(--shadow-card)] " \
            "group-data-[night]/fp:in-[.is-drawn]:bg-[color-mix(in_srgb,var(--side)_70%,black)] group-data-[night]/fp:in-[.is-drawn]:border-[color-mix(in_srgb,var(--side)_60%,var(--accent))] group-data-[night]/fp:in-[.is-drawn]:shadow-none " \
            "@max-[520px]:py-[.2rem] @max-[520px]:px-[.3rem] @max-[520px]:rounded-[7px]".freeze
  # Cômodo com luz acesa: brilha na cor real (à noite mais forte, com o brilho por dentro).
  FP_ROOM_ON = "border-[color-mix(in_srgb,var(--glow,var(--warn))_55%,transparent)]! bg-[color-mix(in_srgb,var(--glow,var(--warn))_14%,transparent)]! duration-[.6s] " \
               "group-data-[night]/fp:bg-[color-mix(in_srgb,var(--glow,var(--warn))_24%,color-mix(in_srgb,var(--side)_70%,black))]! group-data-[night]/fp:border-[color-mix(in_srgb,var(--glow,var(--warn))_65%,transparent)]! " \
               "group-data-[night]/fp:shadow-[inset_0_0_3rem_color-mix(in_srgb,var(--glow,var(--warn))_35%,transparent)]!".freeze
  FP_ROOM_NAME = "text-[clamp(.6rem,2.2cqi,.8rem)] font-extrabold text-ink-2 tracking-[.01em] truncate " \
                 "group-data-[night]/fp:text-[color-mix(in_srgb,var(--side-ink)_75%,transparent)]".freeze
  FP_AT = "absolute z-[2] grid justify-items-center gap-[.15rem] -translate-x-1/2 -translate-y-1/2".freeze
  FP_PIN = "relative grid place-items-center size-9 p-0 rounded-full cursor-pointer border-2 " \
           "shadow-[0_4px_12px_-4px_color-mix(in_srgb,var(--ink)_35%,transparent)] transition-[background,color,box-shadow,transform] duration-300 " \
           "hover:scale-[1.08] active:scale-[.94] focus-visible:outline-3 focus-visible:outline-accent focus-visible:outline-offset-2 " \
           "@max-[520px]:size-7 @max-[520px]:border-[1.5px] @max-[520px]:[&_svg]:size-[.85rem]".freeze
  FP_PIN_OFF = "bg-surface border-[color-mix(in_srgb,var(--line)_80%,transparent)] group-data-[night]/fp:bg-[color-mix(in_srgb,var(--side)_75%,black)] " \
               "group-data-[night]/fp:border-[color-mix(in_srgb,var(--side)_60%,var(--accent))]".freeze
  FP_PIN_ON = "text-[var(--on-accent)] bg-[image:var(--grad)] border-transparent".freeze
  FP_PIN_ALERT = "text-[var(--on-accent)] bg-[image:linear-gradient(135deg,var(--danger),color-mix(in_srgb,var(--danger)_70%,black))] border-transparent ss-anim-ping".freeze
  FP_PIN_LIGHT = "text-[color-mix(in_srgb,var(--glow,var(--warn))_20%,black)] bg-[var(--glow,var(--warn))] border-transparent " \
                 "shadow-[0_0_0_4px_color-mix(in_srgb,var(--glow,var(--warn))_30%,transparent),0_0_22px_4px_color-mix(in_srgb,var(--glow,var(--warn))_65%,transparent)] " \
                 "group-data-[night]/fp:before:content-[''] before:absolute before:-inset-[260%] before:-z-1 before:rounded-full before:pointer-events-none " \
                 "before:bg-[radial-gradient(circle,color-mix(in_srgb,var(--glow,var(--warn))_55%,transparent)_0%,color-mix(in_srgb,var(--glow,var(--warn))_18%,transparent)_35%,transparent_68%)] " \
                 "before:mix-blend-screen before:animate-[ss-a-breathe_4s_ease-in-out_infinite] motion-reduce:before:animate-none".freeze
  FP_PIN_FAN = "[&_svg]:animate-[ss-a-spin_var(--ss-anim-dur,1.2s)_linear_infinite] motion-reduce:[&_svg]:animate-none".freeze
  FP_VAL = "py-[.05rem] px-[.4rem] rounded-full text-[.68rem] font-bold text-ink bg-[color-mix(in_srgb,var(--surface)_88%,transparent)] " \
           "shadow-[var(--shadow-card)] whitespace-nowrap @max-[520px]:text-[.58rem] @max-[520px]:py-0 @max-[520px]:px-[.3rem]".freeze
  # Editor: o quadro de arrastar e as linhas de cada pino/cômodo.
  FPE_CANVAS = "relative overflow-hidden rounded-[14px] bg-field isolate @container mt-2 touch-none [&.is-drawn]:aspect-[16/10] " \
               "[&.is-drawn]:bg-[radial-gradient(circle,color-mix(in_srgb,var(--muted)_22%,transparent)_1px,transparent_1.5px)] [&.is-drawn]:bg-[length:18px_18px]".freeze
  FPE_ROW = "dw-fpe-row flex flex-wrap items-center gap-[.4rem] pb-[.4rem] border-b border-[color-mix(in_srgb,var(--line)_60%,transparent)] [&>.flex-1]:basis-[14rem]".freeze
  FPE_NUM = "flex! items-center gap-[.3rem] text-[.72rem] text-muted [&_input]:w-[4.6rem]".freeze

  def dw_fp_room_class(on:) = [ FP_ROOM, (FP_ROOM_ON if on) ].compact.join(" ")

  def dw_fp_pin_class(on:, light:, alert:, fan:, off_line:)
    look = if !on then FP_PIN_OFF
    elsif light then FP_PIN_LIGHT
    elsif alert then FP_PIN_ALERT
    else FP_PIN_ON
    end
    ink = if off_line then "text-danger border-dashed"
    elsif !on then "text-muted group-data-[night]/fp:text-[color-mix(in_srgb,var(--side-ink)_60%,transparent)]"
    end
    [ FP_PIN, look, ink, (FP_PIN_FAN if fan) ].compact.join(" ")
  end
end
