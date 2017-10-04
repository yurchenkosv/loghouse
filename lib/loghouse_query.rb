require 'loghouse_query/parsers'
require 'loghouse_query/storable'
require 'loghouse_query/pagination'
require 'log_entry'

class LoghouseQuery
  include Parsers
  include Storable
  include Pagination

  LOGS_TABLE          = ENV.fetch('CLICKHOUSE_LOGS_TABLE')          { 'logs6' }
  TIMESTAMP_ATTRIBUTE = ENV.fetch('CLICKHOUSE_TIMESTAMP_ATTRIBUTE') { 'timestamp' }
  NSEC_ATTRIBUTE      = ENV.fetch('CLICKHOUSE_NSEC_ATTRIBUTE')      { 'nsec' }

  DEFAULTS = {
    id:        nil,
    name:      nil,
    query:     nil,
    time_from: 'now-7d',
    time_to:   'now',
    position:  nil
  } # Trick for all-attributes-hash in correct order in insert

  attr_accessor :attributes

  def initialize(attrs = {})
    attrs.symbolize_keys!
    @attributes = DEFAULTS.dup
    @attributes.each do |k, v|
      @attributes[k] = attrs[k] if attrs[k].present?
    end
    @attributes[:id] ||= SecureRandom.uuid
  end

  def id
    attributes[:id]
  end

  def order_by
    [attributes[:order_by], "#{TIMESTAMP_ATTRIBUTE} DESC", "#{NSEC_ATTRIBUTE} DESC"].compact.join(', ')
  end

  def to_clickhouse
    params = {
      select: '*',
      from: LOGS_TABLE,
      order: order_by,
      limit: limit
    }
    if (where = to_clickhouse_where)
      params[:where] = where
    end

    params
  end

  def result
    @result ||= LogEntry.from_result_set Clickhouse.connection.select_rows(to_clickhouse)
  end

  def validate!
    to_clickhouse # sort of validation: will fail if queries is not correct

    super
  end

  protected

  def to_clickhouse_time(time)
    time = Time.zone.parse(time) if time.is_a? String

    "toDateTime('#{time.utc.strftime('%Y-%m-%d %H:%M:%S')}')"
  end

  def to_clickhouse_where
    where_parts = []
    where_parts << query_to_clickhouse(parsed_query[:query]) if parsed_query

    where_parts << "#{TIMESTAMP_ATTRIBUTE} >= #{to_clickhouse_time parsed_time_from}" if parsed_time_from
    where_parts << "#{TIMESTAMP_ATTRIBUTE} <= #{to_clickhouse_time parsed_time_to}" if parsed_time_to

    where_parts << to_clickhouse_pagination_where
    where_parts.compact!

    return if where_parts.blank?

    "(#{where_parts.join(') AND (')})"
  end


  def query_to_clickhouse(query)
    result = "(#{expression_to_clickhouse(query[:expression])})"

    if query[:subquery]
      op = query_operator_to_clickhouse(query[:subquery][:q_op])
      query_result = query_to_clickhouse(query[:subquery][:query])

      result = [result, "#{op}\n", query_result].join(' ')
    end

    result
  end

  def expression_to_clickhouse(expression)
    op =  if expression[:not_null]
            'not_null'
          elsif expression[:is_null]
            'is_null'
          elsif expression[:is_true]
            'is_true'
          elsif expression[:is_false]
            'is_false'
          else
            expression[:e_op]
          end

    key = expression[:key]
    str_val = expression[:str_value]
    num_val = expression[:num_value]

    case op
    when 'not_null', 'is_null'
      "#{'NOT ' if op == 'not_null'}has(null_fields.names, '#{key}')"
    when 'is_true', 'is_false'
      "has(boolean_fields.names, '#{key}') AND boolean_fields.values[indexOf(boolean_fields.names, '#{key}')] = #{op == 'is_true' ? 1 : 0}"
    when '>', '<', '<=', '>='
      val = (num_val || str_val).to_f
      "has(number_fields.names, '#{key}') AND number_fields.values[indexOf(number_fields.names, '#{key}')] #{op} #{val}"
    when '=~'
      val = (str_val || num_val).to_s
      val = "/#{val}/" unless val =~ /\/.*\//

      "has(string_fields.names, '#{key}') AND match(string_fields.values[indexOf(string_fields.names, '#{key}')], '#{val}')"
    when '=', '!='
      if (val = str_val)
        val = val.to_s
        if val.include?('%') || val.include?('_')
          "has(string_fields.names, '#{key}') AND #{op == '=' ? 'like' : 'notLike'}(string_fields.values[indexOf(string_fields.names, '#{key}')],'#{val}')"
        else
          "has(string_fields.names, '#{key}') AND string_fields.values[indexOf(string_fields.names, '#{key}')] #{op} '#{val}'"
        end
      else
        val = num_val
        <<~EOS
          CASE
            WHEN has(string_fields.names, '#{key}')
              THEN string_fields.values[indexOf(string_fields.names, '#{key}')] = '#{val}'
            WHEN has(number_fields.names, '#{key}')
              THEN number_fields.values[indexOf(number_fields.names, '#{key}')] = #{val}
            ELSE 0
          END
        EOS
      end
    end
  end

  def query_operator_to_clickhouse(op)
    op.to_s.upcase
  end
end