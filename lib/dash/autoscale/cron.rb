# A five-field cron expression - `minute hour day-of-month month day-of-week` - for the
# schedule windows of a scaled role. Each field is `*`, a number, a range `a-b`, a list
# `a,b` or a step `*/n` / `a-b/n`; day-of-week 0 and 7 are both Sunday. Vixie semantics:
# when both day fields are restricted (neither starts with `*`), a day matches if either
# does. No names, `L`, `W` or `#`.
#
# `match?` takes a time already in the zone the schedule is evaluated in.
class Dash::Autoscale::Cron
  class Error < ArgumentError; end

  Field = Struct.new(:name, :min, :max)

  FIELDS = [
    Field.new("minute", 0, 59),
    Field.new("hour", 0, 23),
    Field.new("day-of-month", 1, 31),
    Field.new("month", 1, 12),
    Field.new("day-of-week", 0, 7)
  ].freeze

  ITEM = /\A(?:(\*)|(\d+)(?:-(\d+))?)(?:\/(\d+))?\z/

  def self.parse(expression)
    new(expression)
  end

  def initialize(expression)
    @expression = expression.to_s.strip
    parts = @expression.split

    unless parts.size == FIELDS.size
      raise Error, "#{@expression.inspect} has #{parts.size} fields, a cron has 5 (minute hour day-of-month month day-of-week)"
    end

    @minutes, @hours, @days, @months, weekdays = FIELDS.zip(parts).map { |field, part| parse_field(field, part) }
    @weekdays = weekdays.map { |day| day % 7 }.to_set
    @days_restricted, @weekdays_restricted = !parts[2].start_with?("*"), !parts[4].start_with?("*")
  end

  def match?(time)
    @minutes.include?(time.min) && @hours.include?(time.hour) && @months.include?(time.month) && day_match?(time)
  end

  def to_s
    @expression
  end

  private
    def day_match?(time)
      day, weekday = @days.include?(time.day), @weekdays.include?(time.wday)

      @days_restricted && @weekdays_restricted ? day || weekday : day && weekday
    end

    def parse_field(field, part)
      part.split(",", -1).flat_map { |item| parse_item(field, item) }.to_set
    end

    def parse_item(field, item)
      match = ITEM.match(item)
      unless match && (match[1] || match[3] || !match[4])
        raise Error, "#{field.name}: #{item} is not supported, use numbers, *, ranges (a-b), lists (a,b) and steps (*/n, a-b/n)"
      end

      star, first, last, step = match.captures
      from, to = star ? [ field.min, field.max ] : [ Integer(first, 10), Integer(last || first, 10) ]
      step = step ? Integer(step, 10) : 1

      [ from, to ].each { |value| raise Error, "#{field.name}: #{value} is outside #{field.min}-#{field.max}" unless value.between?(field.min, field.max) }
      raise Error, "#{field.name}: #{item} is a reversed range" if from > to
      raise Error, "#{field.name}: #{item} needs a step of at least 1" if step < 1

      (from..to).step(step).to_a
    end
end
