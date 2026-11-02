require "strscan"

module Assist
  # Frases-modelo no formato do HA (hassil), as mesmas para as intenções
  # nativas, as frases do usuário e o gatilho por frase:
  #   [opcional]   (um|outro)   {slot}
  # "ligar [a|o] {name} [da {area}]" → Regexp sobre a frase normalizada
  # (sem acento, minúsculas), com grupos nomeados para os slots. Palavra
  # literal casa inteira (\b): "[o] {name}" não come o "o" de "oficina".
  # Slot de número (`numbers`) só aceita algarismos ("50", "22.5").
  module Sentences
    NUMBER = '\d+(?:\.\d+)?'
    CACHE_MAX = 500
    @cache = {}

    module_function

    def compile(template, numbers: [])
      key = [ template, numbers ]
      return @cache[key] if @cache.key?(key)

      @cache.clear if @cache.size >= CACHE_MAX
      @cache[key] = Regexp.new("\\A\\s*#{body(template.to_s, numbers.map(&:to_s))}\\s*\\z")
    end

    # {slot => valor} (sem espaço nas pontas) ou nil.
    def match(template, norm, numbers: [])
      m = compile(template, numbers: numbers).match(norm) or return
      m.named_captures.transform_values { |v| v&.strip }.compact
    end

    # Erro de sintaxe (para o formulário) ou nil.
    def error(template)
      t = template.to_s
      return I18n.t("assist.sentences.errors.empty") if t.strip.empty?
      return I18n.t("assist.sentences.errors.brackets") unless balanced?(t)

      compile(t)
      nil
    rescue RegexpError
      I18n.t("assist.sentences.errors.invalid")
    end

    def slots(template) = template.to_s.scan(/\{(\w+)\}/).flatten.uniq

    def balanced?(t)
      stack = []
      t.each_char do |c|
        case c
        when "[", "(" then stack << c
        when "]" then return false unless stack.pop == "["
        when ")" then return false unless stack.pop == "("
        end
      end
      stack.empty?
    end

    def body(template, numbers)
      s = StringScanner.new(template)
      out = +""
      until s.eos?
        if s.scan(/\{(\w+)\}/)
          name = s[1]
          out << "\\s*\\b(?<#{name}>#{numbers.include?(name) ? NUMBER : '.+?'})\\b\\s*"
        elsif s.scan(/\[/) then out << "(?:"
        elsif s.scan(/\]/) then out << ")?"
        elsif s.scan(/\(/) then out << "(?:"
        elsif s.scan(/\)/) then out << ")"
        elsif s.scan(/\|/) then out << "|"
        elsif s.scan(/[^\[\]()|{]+/)
          words = Assist.normalize(s.matched).split
          out << "\\s*#{words.map { |w| "\\b#{Regexp.escape(w)}\\b" }.join('\\s+')}\\s*" if words.any?
        else s.getch
        end
      end
      out
    end
  end
end
