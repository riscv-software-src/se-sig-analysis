# Wraps an Integer or Array with an associated description
class Stat
  # @return [Integer,Array] Underlying value
  attr_reader :value
  
  # @return [String] Text description
  attr_reader :desc

  # @param value [Integer,Array] Initial value of the stat
  # @param desc [String] String description of the stat
  def initialize(value, desc)
    @value = value
    @desc = desc
  end

  # @param other [Integer, Array] Add other to the underlying value, and return a new Stat
  def +(other)
    Stat.new(@value + other, @desc)
  end

  # @param idx [Integer] Array index
  # @raise [NoMethodError] When underlying type is not an Array
  def [](idx)
    raise NoMethodError, 'Underlying stat value is not an Array' unless @value.respond_to?(:[])

    @value[idx]
  end

  # @param idx [Integer] Array index
  # @param v [Integer] Write value
  # @raise [NoMethodError] When underlying type is not an Array
  def []=(idx, v)
    @value[idx] = v
  end
end

module StatUtil
  def self.gen_obj_schema(obj)
    schema = {}
    obj.each do |k, v|
      if v.is_a?(Hash)
        schema[k] = {
          'type': 'object',
          'properties': gen_obj_schema(v)
        }
      elsif v.value.is_a?(Array)
        raise 'TODO: non-int array elements' unless v.value.all?{ |e| e.is_a?(Integer) }

        schema[k] = {
          'type': 'array',
          'items': {
            'type': 'number',
            'minItems': v.value.size,
            'maxItems': v.value.size
          },
          'description': v.desc
        }
      elsif v.value.is_a?(Integer)
        schema[k] = {
          'type': 'number',
          'description': v.desc
        }
      else 
        raise "unexpected #{v.value.class}"
      end
    end
    schema
  end
  private_class_method :gen_obj_schema

  def self.gen_schema(stats, path)
    {
      '$schema': 'https://json-schema.org/draft/2020-12/schema',
      '$id': "file://#{path}",
      'title': 'Stat schema',
      'description': 'Schema for elf estimator statistics',
      'type': 'object',
      'properties': gen_obj_schema(stats)
    }
  end
end

# class that wraps an obj/hash, and runs
# various Jasonata-like queries on it
class Jsonata
  def initialize(obj)
    @obj = obj
  end

  def _paths(query_parts, obj_so_far, path_so_far, discovered_paths)
    if query_parts.empty?
      # we've reached the endpoint, add everything we can find from here
      if obj_so_far.is_a?(Hash)
        obj_so_far.each do |k,v|
          _paths([], v, path_so_far + ".#{k}", discovered_paths)
        end
      elsif obj_so_far.is_a?(Array)
        obj_so_far.each_index do |i|
          _paths([], obj_so_far[i], path_so_far + "[#{idx}]", discovered_paths)
        end
      elsif obj_so_far.is_a?(Integer)
        discovered_paths << path_so_far
      else
        raise "? #{obj_so_far.class}"
      end
      return
    end

    if obj_so_far.is_a?(Hash)
       if query_parts[0] == '*'
        obj_so_far.each do |k, v|
          _paths(query_parts[1..], v, path_so_far + ".#{k}", discovered_paths)
        end
      elsif obj_so_far.key?(query_parts[0])
        _paths(query_parts[1..], obj_so_far[query_parts[0]], path_so_far + ".#{query_parts[0]}", discovered_paths)
      elsif obj_so_far.key?(query_parts[0].to_sym)
        _paths(query_parts[1..], obj_so_far[query_parts[0].to_sym], path_so_far + ".#{query_parts[0]}", discovered_paths)
      end
    elsif obj_so_far.is_a?(Integer)
      # endpoint
    elsif obj_so_far.is_a?(Array)
      if query_parts[0][0] == '['
        if query_parts[0] =~ /^\[\d\]$/
          idx = $1.to_i
          if idx < obj_so_far.size
            _paths(query_parts[1..], obj_so_far[idx], path_so_far + "[#{idx}]", discovered_paths)
          end
        end
      end
    else
      raise "? #{obj_so_far.class}"
    end
  end
  private :_paths

  # given a query, return all matching paths
  # @param query [String] The query to match on @obj
  def expand_paths(query)
    parts = query.gsub('[', '.[').split('.')
    discovered_paths = []
    _paths(parts, @obj, "", discovered_paths)
    discovered_paths.map { |s| s.delete_prefix('.') }
  end

  def _value(query_parts, obj)
    return obj if query_parts.empty?

    if obj.is_a?(Hash)
      raise "path not in obj" unless obj.key?(query_parts[0]) || obj.key?(query_parts[0].to_sym)

      if obj.key?(query_parts[0].to_s)
        return _value(query_parts[1..], obj[query_parts[0].to_s])
      elsif obj.key(query_parts[0].to_sym)
        return _value(query_parts[1..], obj[query_parts[0].to_sym])
      end
    elsif obj.is_a?(Array)
      if query_parts =~ /^\[\d\]$/
        idx = $1.to_i
        raise "Array index out of bounds" if idx >= obj.size

        return _value(query_parts[1..], obj[idx])
      end
    else
      raise "Bad path"
    end
  end

  # given a query, return the value it points to
  # @param query [String] the JSONata-like query
  def value(query)
    parts = query.gsub('[', '.[').split('.')
    _value(parts, @obj)
  end
end
