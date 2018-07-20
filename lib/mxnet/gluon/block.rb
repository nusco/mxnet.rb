require 'mxnet/gluon'
require 'mxnet/gluon/parameter'
require 'mxnet/ndarray'

module MXNet::Gluon
  ##
  # Scope for collecting child Blocks.
  #
  class BlockScope
    def initialize(block = nil)
      @block = block
      @counters = Hash.new(-1)
    end
    attr_accessor :block
    attr_accessor :counters
    def self.create(prefix, params, hint)
      current =
        Thread.current['mxnet_gluon_blockscope_current'] ||=
        BlockScope.new
      if current.block
        if prefix.nil?
          prefix = "#{hint}#{current.counters[hint] += 1}_"
        end
        if params.nil?
          params = ParameterDict.new(prefix: "#{current.block.prefix}#{prefix}")
        else
          params = ParameterDict.new(prefix: "#{current.block.prefix}#{prefix}", shared: params)
        end
        ["#{current.block.prefix}#{prefix}", params]
      else
        if prefix.nil?
          prefix = "#{hint}#{current.counters[hint] += 1}_"
        end
        if params.nil?
          params = ParameterDict.new(prefix: prefix)
        else
          params = ParameterDict.new(prefix: params.prefix, shared: params)
        end
        [prefix, params]
      end
    end
    def call(block)
      previous = Thread.current['mxnet_gluon_blockscope_current']
      Thread.current['mxnet_gluon_blockscope_current'] = block.scope
      yield
    ensure
      Thread.current['mxnet_gluon_blockscope_current'] = previous
    end
  end
  ##
  # Base class for all neural network layers and models. Your models
  # should subclass this class.
  #
  class Block
    def initialize(prefix: nil, params: nil, **kwargs)
      @scope = BlockScope.new(self)
      @prefix, @params = BlockScope.create(prefix, params, hint)
      @reg_parameters = {}
      @reg_children = {}
    end
    ##
    # Scope of this block.
    #
    attr_reader :scope
    ##
    # Prefix of this Block.
    #
    attr_reader :prefix
    ##
    # Returns this Block's ParameterDict (does not include its
    # children's parameters).
    #
    attr_reader :params
    ##
    # Enters a name space managing Block names.
    #
    #     self.with_name_scope do
    #       self.dense = MXNet::Gluon::NN.Dense(20)
    #     end
    #
    def with_name_scope(&proc)
      @scope.call(self, &proc)
    end
    ##
    # Returns a ParameterDict containing this Block's and all of its
    # children's Parameters. Also can return the Parameters that match
    # some given regular expressions.
    #
    # For example, collect the specified Parameters for
    # 'conv1_weight', 'conv1_bias', 'fc_weight' and 'fc_bias':
    #
    #     model.collect_params('conv1_weight|conv1_bias|fc_weight|fc_bias')
    #
    # or, alternatively, collect all parameters whose names end with
    # 'weight' or 'bias':
    #
    #     model.collect_params('.*weight|.*bias')
    #
    # ====Parameters
    #
    # +select+:: (regexp) Regular expressions to match Parameters.
    #
    # ====Returns
    #
    # The filtered ParameterDict.
    #
    def collect_params(select = nil)
      ret = ParameterDict.new(prefix: @params.prefix)
      if select
        ret.update(@params.select { |k, v| k =~ select })
      else
        ret.update(@params)
      end
      @reg_children.each do |_, child|
        ret.update(child.collect_params(select))
      end
      ret
    end
    ##
    # Registers block as a child of self. Blocks assigned as
    # attributes will be registered automatically.
    #
    def register_child(block, name)
      @reg_children[name] = block
    end
    ##
    # Calls #forward. Only accepts positional arguments.
    #
    #
    def [](*args)
      forward(*args)
    end
    ##
    # Override to implement forward computation using NDArray. Only
    # accepts positional arguments.
    #
    # ====Parameters
    #
    # +args+:: (array of NDArray) Input tensors.
    #
    def forward(*args)
      raise NotImplementedError
    end
    private
    def method_missing(sym, value = nil)
      name = sym.to_s
      if name[-1] == '='
        name = name[0...-1]
        case value
        when MXNet::Gluon::Block
          register_child(value, name)
        when MXNet::Gluon::Parameter
          @reg_parameters[name] = value
        else
          raise TypeError, "value must be either " \
                           "MXNet::Gluon::Block or " \
                           "MXNet::Gluon::Parameter"
        end
      else
        @reg_children[name] or
          @reg_parameters[name] or
          super
      end
    end
    def hint
      self.class.name.split('::').last.downcase
    end
  end
  ##
  # HybridBlock supports forwarding with both Symbol and NDArray.
  #
  class HybridBlock < Block
    def initialize(**kwargs)
      super(**kwargs)
      @cached_graph = nil
    end
    def register_child(block, name)
      unless block.is_a?(MXNet::Gluon::HybridBlock)
        raise RuntimeError,
              "Children of a HybridBlock must also be a HybridBlock, " \
              "but #{block} has type #{block.class}. If you are using " \
              "Sequential, please try HybridSequential instead."
      end
      super
    end
    ##
    # Defines the forward computation. Arguments can be either Symbol
    # or NDArray.
    #
    # ====Parameters
    #
    # +args+:: (array of Symbol or NDArray) Input tensors.
    #
    def forward(*args)
      case args.first
      when MXNet::Symbol
        kwargs = {}
        hybrid_forward(MXNet::Symbol, *args, **kwargs)
      when MXNet::NDArray
        ctx = args.first.context
        begin
          kwargs = @reg_parameters.inject({}) do |acc, (i, j)|
            acc[i.to_sym] = j.data(ctx: ctx)
            acc
          end
        rescue MXNet::Gluon::DeferredInitializationError
          deferred_infer_shape(*args)
          @params.each do |_, param|
            # NOTE: invoking private method on Parameter
            param.send(:finish_deferred_init)
          end
          retry
        end
        hybrid_forward(MXNet::NDArray, *args, **kwargs)
      else
        raise ArgumentError, 'only Symbol or NDArray are supported'
      end
    end
    ##
    # Override to construct symbolic graph for this Block.
    #
    # ====Parameters
    #
    # +args+:: (array of NDArray or Symbol) Input tensors.
    #
    #
    def hybrid_forward(clazz, *args)
      raise NotImplementedError
    end
    def infer_type(*args)
      infer_attrs('infer_type', 'dtype', *args)
    end
    def infer_shape(*args)
      infer_attrs('infer_shape', 'shape', *args)
    end
    def deferred_infer_shape(*args)
      infer_shape(*args)
    end
    private
    def get_graph(*args)
      @cached_graph ||=
        begin
          inputs = (0...args.length).map do |i|
            MXNet::Symbol.var("data#{i}")
          end
          params = @reg_parameters.inject({}) do |acc, (i, j)|
            acc[i.to_sym] = j.var
            acc
          end
          [inputs, hybrid_forward(MXNet::Symbol, *inputs, **params)]
        end
    end
    def clear_cache
      @cached_graph = nil
    end
    ##
    # Infer attributes.
    #
    def infer_attrs(fn, attr, *args)
      inputs, output = get_graph(*args)
      arg_attrs, _, aux_attrs =
        output.send(fn, inputs.zip(args).inject({}) { |a, (i, j)| a[i.name] = j.send(attr) ; a })
      sdict = output.list_arguments.zip(arg_attrs).to_h
                .merge(output.list_auxiliary_states.zip(aux_attrs).to_h)
      collect_params.values.each do |value|
        value.send("#{attr}=", sdict[value.name.to_sym])
      end
    end
  end
end