module MXNet
  module Utils
    module_function

    def dtype_id(name_or_id)
      case name_or_id
      when String, ::Symbol
        MXNet::DType.name2id(name_or_id)
      when Integer
        name_or_id
      else
        raise TypeError, "wrong type of dtype: #{name_or_id.class} (expected Symbol or Integer)"
      end
    end

    def dtype_name(name_or_id)
      case name_or_id
      when String, ::Symbol
        name_or_id.to_s
      when Integer
        MXNet::DType.id2name(name_or_id)
      else
        raise TypeError, "wrong type of dtype: #{name_or_id.class} (expected Symbol or Integer)"
      end
    end

    def define_operation_delegator(mod, handle, op_info, fname='(eval)', lineno=1)
      dtype_name = nil
      ary_name = nil
      signature = []
      ndsignature = []
      ndarg_names = []
      kwarg_names = []
      op_info.args.each do |arg|
        name = arg.name
        case name.to_s
        when 'begin', 'end', /\A[A-Z]/
          name = :"_#{name}"
        end
        if name == :dtype
          dtype_name = name
          signature << "#{name}=nil"
        elsif arg.type_info.start_with?('NDArray') || arg.type_info.start_with?('Symbol')
          if arg.type_info.end_with?('[]')
            raise "Op can only have one argument with variable size and it must be the last argument." if ary_name
            ndsignature << "#{name}"
            ary_name = name
          else
            ndsignature << "#{name}=nil"
            ndarg_names << name
          end
        else
          signature << "#{name}=nil"
          kwarg_names << name
        end
      end
      signature << 'out=nil'
      signature << 'name=nil'
      signature << '**kwargs'
      signature = ndsignature + signature

      code = []
      if ary_name
        code << <<-RUBY
def #{op_info.name}(*#{ary_name}, **kwargs)
  #{ary_name}.each do |i|
    raise TypeError, "unexpected positional arguments \#{i.class} (expect NDArray)" unless i.kind_of? NDArray
  end
  ndargs = #{ary_name}
        RUBY
        if dtype_name
          code << <<-RUBY
  if kwargs.has_key?(:#{dtype_name})
    kwargs[:#{dtype_name}] = MXNet::DType.name(#{dtype_name})
    # TDOD: dtype normalization
  end
          RUBY
        end
        code << <<-RUBY
  kwargs.delete_if { |k, v| v.nil? }
  _ = kwargs.delete(:name)
  out = kwargs.delete(:out)
  keys = kwargs.keys
  vals = kwargs.values
        RUBY
      else # if ary_name
        code << <<-RUBY
def #{op_info.name}(#{signature.join(', ')})
  ndargs = []
  kwargs.delete_if { |k, v| v.nil? }
  keys = kwargs.keys
  vals = kwargs.values
        RUBY
        ndarg_names.each do |name|
          code << <<-RUBY
  if #{name}
    raise TypeError, "unexpected type of argument \#{#{name}.class} (expected NDArray)" unless #{name}.kind_of? NDArray
    ndargs << #{name}
  end
          RUBY
        end
        kwarg_names.each do |name|
          code << <<-RUBY
  if #{name}
    keys << :#{name}
    vals << #{name}
  end
          RUBY
        end
        if dtype_name
          code << <<-RUBY
  if #{dtype_name}
    keys << :#{dtype_name}
    vals << MXNet::DType.name(#{dtype_name})
  end
          RUBY
        end
      end # if ary_name

      code << <<-RUBY
  return LibMXNet.imperative_invoke(#{handle}, ndargs, keys, vals, out)
end
module_function :#{op_info.name}
      RUBY

      mod.module_eval(code.join(''), fname, lineno)
    end
  end
end
