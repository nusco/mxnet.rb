module MXNet
  class NDArray
    include HandleWrapper
    include Enumerable

    def self.ones(shape, ctx=nil, dtype=:float32, **kwargs)
      ctx ||= Context.default
      dtype = Utils.dtype_id(dtype)
      Internal._ones(shape: shape, ctx: ctx, dtype: dtype, **kwargs)
    end

    def self.zeros(shape, ctx=nil, dtype=:float32, **kwargs)
      ctx ||= Context.default
      dtype = Utils.dtype_id(dtype)
      Internal._zeros(shape: shape, ctx: ctx, dtype: dtype, **kwargs)
    end

    def self.arange(start, stop=nil, step: 1.0, repeat: 1, ctx: nil, dtype: :float32)
      ctx ||= Context.default
      dtype = Utils.dtype_name(dtype)
      Internal._arange(start: start, stop: stop, step: step, repeat: repeat, dtype: dtype, ctx: ctx)
    end

    def self.full(shape, val, ctx: nil, dtype: :float32, out: nil)
      ctx ||= Context.default
      out ||= empty(shape, ctx: ctx, dtype: dtype)
      out[0..-1] = val
      return out
    end

    def inspect
      shape_info = shape.join('x')
      ary = to_narray.inspect.lines[1..-1].join
      "\n#{ary}\n<#{self.class} #{shape_info} @#{context}>"
    end

    def context
      dev_typeid, dev_id = _get_context_params
      Context.new(dev_typeid, dev_id)
    end

    # Returns an array on the target device with the same value as this array.
    #
    # If the target context is the same as `self.context`, then `self` is returned.
    # Otherwise, a copy is made.
    #
    # @param context [MXNet::Context] The target context.
    # @return [NDArray, CSRNDArray, RowSparseNDArray] The target array.
    def as_in_context(context)
      return self if self.context == context
      copy_to(context)
    end

    def each
      return enum_for unless block_given?

      i = 0
      n = shape[0]
      while i < n
        yield self[i]
        i += 1
      end
    end

    # Returns a sliced view of this array.
    #
    # @param [Integer, Range, Array] key  Indexing key.
    # @return [NDArray] a sliced view of this array.
    def [](*key)
      key = key[0] if key.length == 1
      case key
      when Integer
        if key > shape[0] - 1
          raise IndexError, "index #{key} is out of bounds for axis 0 with size #{shape[0]}"
        end
        _at(key)
      when Range, Enumerator
        start, stop, step = MXNet::Utils.decompose_slice(key)
        if step && step != 1
          raise ArgumentError, 'slice step cannot be zero' if step == 0
          Ops.slice(self, begin: [start], end: [stop], step: [step])
        elsif start || stop
          _slice(start, stop)
        else
          self
        end
      when Array
        keys = key
        raise ArgumentError, "index cannot be an empty array" if keys.empty?
        shape = self.shape
        unless shape.length >= keys.length
          raise IndexError, "Slicing dimensions exceeds array dimensions, #{keys.length} vs #{shape.length}"
        end
        begins, ends, steps, kept_axes = [], [], [], []
        keys.each_with_index do |slice_i, idx|
          case slice_i
          when Integer
            begins << slice_i
            ends << slice_i + 1
            steps << 1
          when Range, Enumerator
            start, stop, step = MXNet::Utils.decompose_slice(slice_i)
            raise ArgumentError, "index=#{keys} cannot have slice=#{slice_i} with step=0" if step == 0
            begins << (start || MXNet::None)
            ends << (stop || MXNet::None)
            steps << (step || MXNet::None)
            kept_axes << idx
          else
            raise IndexError, "NDArray does not support slicing with index=#{slice_i} of type #{slice_i.class}"
          end
        end
        kept_axes.concat([*(keys.length) ... shape.length])
        sliced_nd = Ops.slice(self, begin: begins, end: ends, step: steps)
        return sliced_nd if kept_axes.length == shape.length

        # squeeze sliced_shape to remove the axes indexed by integers
        out_shape = []
        sliced_shape = sliced_nd.shape
        kept_axes.each do |axis|
          out_shape << sliced_shape[axis]
        end
        # if key is an array of integers, still need to keep 1 dim
        # while in Numpy, the output will become an value instead of an ndarray
        out_shape << 1 if out_shape.length == 0
        if out_shape.inject(:*) != sliced_shape.inject(:*)
          raise "out_shape=#{out_shape} has different size than sliced_shape=#{sliced_shape}"
        end
        sliced_nd.reshape(out_shape)
      else
        raise IndexError, "NDArray does not support slicing with key #{key} of type #{key.class}"
      end
    end

    def []=(*key, value)
      key = key[0] if key.length == 1
      shape = self.shape
      case key
      when Integer
        self[key][0..-1] = value
        return value
      when Range, Enumerator
        start, stop, step = MXNet::Utils.decompose_slice(key)
        if step.nil? || step == 1
          unless start == 0 && (stop.nil? || stop == shape[0])
            sliced_arr = _slice(start, stop)
            sliced_arr[0..-1] = value
            return value
          end
          _fill_by(value)
          return value
        end
        # non-trivial step, use _slice_assign or _slice_assign_scalar
        key = [key]
      end
      unless key.is_a? Array
        raise TypeError, "key=#{key} must be an array of slices and integers"
      end
      if key.length > shape.length
        raise ArgumentError, "Indexing dimensions exceed array dimensions, #{key.length} vs #{shape.length}"
      end
      begins, ends, steps = [], [], []
      out_shape, value_shape = [], []
      key.each_with_index do |slice_i, idx|
        dim_size = 1
        case slice_i
        when Integer
          begins << slice_i
          ends << slice_i + 1
          steps << 1
        when Range, Enumerator
          start, stop, step = MXNet::Utils.decompose_slice(slice_i)
          raise ArgumentError, "index=#{keys} cannot have slice=#{slice_i} with step=0" if step == 0
          begins << (start || MXNet::None)
          ends << (stop || MXNet::None)
          steps << (step || MXNet::None)

          # noremalize slice components
          len = shape[idx]
          step ||= 1
          if start.nil?
            start = step > 0 ? 0 : len - 1
          elsif start < 0
            start += len
            raise IndexError, "slicing start #{start - len} exceeds limit of #{len}" if start < 0
          elsif start >= len
            raise IndexError, "slicing start #{start} exceeds limit of #{len}"
          end
          if stop.nil?
            stop = step > 0 ? len : -1
          elsif stop < 0
            stop += len
            raise IndexError, "slicing stop #{stop - len} exceeds limit of #{len}" if stop < 0
          elsif stop >= len
            raise IndexError, "slicing stop #{stop} exceeds limit of #{len}"
          end

          dim_size = if step > 0
                       (stop - start - 1).div(step) + 1
                     else
                       (start - stop - 1).div(-step) + 1
                     end
           value_shape << dim_size
        else
          raise ArgumentError, "NDArray does not support index=#{slice_i} of type #{slice_i.class}"
        end
        out_shape << dim_size
      end
      out_shape.concat(shape[key.length..-1])
      value_shape.concat(shape[key.length..-1])
      # if key contains all integers, value_shape should be [1]
      value_shape << 1 if value_shape.empty?

      case value
      when Numeric
        Internal._slice_assign_scalar(self, scalar: Float(value), begin: begins, end: ends, step: steps, out: self)
      else
        value_nd = _prepare_value_nd(value, value_shape)
        value_nd = value_nd.reshape(out_shape) if value_shape != out_shape
        Internal._slice_assign(self, value_nd, begin: begins, end: ends, step: steps, out: self)
      end

      return value
    end

    def _fill_by(value)
      case value
      when NDArray
        if __mxnet_handle__ != value.send(:__mxnet_handle__)
          Internal._copyto(value, out: self)
        end
      when Numeric
        Internal._full(shape: self.shape, ctx: self.context,
                       dtype: self.dtype, value: value.to_f, out: self)
      else
        case
        when value.is_a?(Array)
          raise NotImplementedError, "Array is not supported yet"
        when defined?(Numo::NArray) && value.is_a?(Numo::NArray)
          # require 'mxnet/narray_helper'
          # TODO: MXNet::NArrayHelper.sync_copyfrom(self, value)
          raise NotImplementedError, "NArray is not supported yet"
        when defined?(NMatrix) && value.is_a?(NMatrix)
          # require 'mxnet/mxnet_helper'
          # TODO: _sync_copyfrom_nmatrix(value)
          raise NotImplementedError, "NMatrix is not supported yet"
        when defined?(Vector) && value.is_a?(Vector)
          raise NotImplementedError, "Vector is not supported yet"
        when defined?(Matrix) && value.is_a?(Matrix)
          raise NotImplementedError, "Matrix is not supported yet"
        else
          raise TypeError, "NDArray does not support assignment with non-array-like " +
            "object #{value.to_s} of #{value.class} class"
        end
      end
    end
    private :_fill_by

    private def _prepare_value_nd(value, value_shape)
      case value
      when Numeric
        value_nd = NDArray.full(shape: value_shape, val: value, ctx: self.context, dtype: self.dtype)
      when NDArray
        value_nd = value.as_in_context(self.context)
        value_nd = value_nd.as_type(self.dtype) if value_nd.dtype != self.dtype
      else
        begin
          value_nd = NDArray.array(value, ctx: self.context, dtype: self.dtype)
        rescue Exception
          raise TypeError, "NDArray does not support assignment with non-array-like object #{value} of type #{value.class}"
        end
      end
      value_nd = value_nd.broadcast_to(value_shape) if value_nd.shape != value_shape
      return value_nd
    end

    def ndim
      shape.length
    end
    alias rank ndim

    def size
      shape.inject(:*)
    end
    alias length size

    def transpose(axes: nil)
      Ops.transpose(self, axes: axes)
    end

    def as_scalar
      unless shape == [1]
        raise TypeError, "The current array is not a scalar"
      end
      to_a[0]
    end

    def +@
      self
    end

    def -@
      Internal._mul_scalar(self, scalar: -1.0)
    end

    def +(other)
      case other
      when NDArray
        Ops.broadcast_add(self, other)
      when Numeric
        Internal._plus_scalar(self, scalar: other)
      else
        raise TypeError, "#{other.class} is not supported"
      end
    end

    def -(other)
      case other
      when NDArray
        Ops.broadcast_sub(self, other)
      when Numeric
        Internal._minus_scalar(self, scalar: other)
      else
        raise TypeError, "#{other.class} is not supported"
      end
    end

    def *(other)
      case other
      when NDArray
        Ops.broadcast_mul(self, other)
      when Numeric
        Internal._mul_scalar(self, scalar: other)
      else
        raise TypeError, "#{other.class} is not supported"
      end
    end

    def /(other)
      case other
      when NDArray
        Ops.broadcast_div(self, other)
      when Numeric
        Internal._div_scalar(self, scalar: other)
      else
        raise TypeError, "#{other.class} is not supported"
      end
    end

    def %(other)
      case other
      when NDArray
        Ops.broadcast_mod(self, other)
      when Numeric
        Internal._mod_scalar(self, scalar: other)
      else
        raise TypeError, "#{other.class} is not supported"
      end
    end

    def **(other)
      case other
      when NDArray
        Ops.broadcast_power(self, other)
      when Numeric
        Internal._power_scalar(self, scalar: other)
      else
        raise TypeError, "#{other.class} is not supported"
      end
    end

    class SwappedOperationAdapter < Struct.new(:scalar)
      def +(ndary)
        ndary + scalar
      end

      def -(ndary)
        Internal._rminus_scalar(ndary, scalar: scalar)
      end

      def *(ndary)
        ndary * scalar
      end

      def /(ndary)
        Internal._rdiv_scalar(ndary, scalar: scalar)
      end

      def %(ndary)
        Internal._rmod_scalar(ndary, scalar: scalar)
      end

      def **(ndary)
        Internal._rpower_scalar(ndary, scalar: scalar)
      end
    end

    def coerce(other)
      [SwappedOperationAdapter.new(other), self]
    end

    def ==(other)
      case other
      when NDArray
        Ops.broadcast_equal(self, other)
      else
        super
      end
    end

    def !=(other)
      case other
      when NDArray
        Ops.broadcast_not_equal(self, other)
      else
        super
      end
    end

    def >(other)
      case other
      when NDArray
        Ops.broadcast_greater(self, other)
      else
        super
      end
    end

    def >=(other)
      case other
      when NDArray
        Ops.broadcast_greater_equal(self, other)
      else
        super
      end
    end

    def <(other)
      case other
      when NDArray
        Ops.broadcast_lesser(self, other)
      else
        super
      end
    end

    def <=(other)
      case other
      when NDArray
        Ops.broadcast_lesser_equal(self, other)
      else
        super
      end
    end

    # Broadcasts the input array to a new shape.
    #
    # Broadcasting is only allowed on axes with size 1.
    # The new shape cannot change the number of dimensions.
    # For example, you could broadcast from shape [2, 1] to [2, 3], but not from
    # shape [2, 3] to [2, 3, 3].
    def broadcast_to(shape)
      # TODO
      raise NotImplementedError
    end

    # Returns a Numo::NArray object with value copied from this array.
    def to_narray
      require 'mxnet/narray_helper'
      self.to_narray
    end

    module Ops
      def self._import_ndarray_operations
        LibMXNet._each_op_names do |op_name|
          op_handle = LibMXNet._get_op_handle(op_name)
          op_info = LibMXNet._get_op_info(op_handle)
        end
      end
    end
  end

  NDArray::CONVERTER = []

  def self.NDArray(array_like, ctx: nil, dtype: :float32)
    ctx ||= MXNet.current_context
    for type, converter in NDArray::CONVERTER
      if array_like.is_a?(type)
        if converter.respond_to? :to_ndarray
          return converter.to_ndarray(array_like, ctx: ctx, dtype: dtype)
        elsif converter.respond_to? :call
          return converter.call(array_like, ctx: ctx, dtype: dtype)
        end
      end
    end
    raise TypeError, "Unable convert #{array_like.class} to MXNet::NDArray"
  end
end
