#include "mxnet_internal.h"

VALUE mxnet_sOpInfo;
VALUE mxnet_sOpArgInfo;

static ID id_handles;
static ID id_descriptions;

static VALUE
lookup_op_info(VALUE klass, VALUE mod, VALUE name)
{
  VALUE hash, op_info;
  hash = rb_ivar_get(mod, id_descriptions);
  if (NIL_P(hash)) {
    rb_raise(rb_eTypeError, "unsupported module");
  }
  if (!RB_TYPE_P(name, T_SYMBOL)) {
    StringValue(name);
    name = rb_to_symbol(name);
  }
  op_info = rb_hash_lookup2(hash, name, Qundef);
  if (op_info == Qundef) {
    rb_raise(rb_eArgError, "unknown operation name");
  }
  return op_info;
}

static void
register_handle(VALUE mod, char const* name, void *handle)
{
  VALUE hash = rb_ivar_get(mod, id_handles);
  if (NIL_P(hash)) {
    hash = rb_hash_new();
    rb_ivar_set(mod, id_handles, rb_hash_new());
  }
  rb_hash_aset(hash, ID2SYM(rb_intern(name)), PTR2NUM(handle));
}

static void
register_description(VALUE mod, char const *name, VALUE description)
{
  VALUE hash = rb_ivar_get(mod, id_descriptions);
  if (NIL_P(hash)) {
    hash = rb_hash_new();
    rb_ivar_set(mod, id_descriptions, rb_hash_new());
  }
  rb_hash_aset(hash, ID2SYM(rb_intern(name)), description);
}

static VALUE
op_arg_info_new(char const *name, char const *type_info, char const *description)
{
  return rb_struct_new(mxnet_sOpArgInfo, ID2SYM(rb_intern(name)), rb_str_new2(type_info), rb_str_new2(description), 0);
}

static VALUE
op_info_new(char const *name, char const *real_name, char const *description,
            mx_uint num_args, char const **arg_names, char const **arg_type_infos,
            char const **arg_descriptions, char const *key_var_num_args,
            char const *return_type)
{
  mx_uint i;
  VALUE args;

  args = rb_ary_new_capa(num_args);
  for (i = 0; i < num_args; ++i) {
    rb_ary_push(args, op_arg_info_new(arg_names[i], arg_type_infos[i], arg_descriptions[i]));
  }

  return rb_struct_new(mxnet_sOpInfo,
    ID2SYM(rb_intern(name)),
    ID2SYM(rb_intern(real_name)),
    rb_str_new2(description),
    args,
    (key_var_num_args && strlen(key_var_num_args) > 0) ? ID2SYM(rb_intern(key_var_num_args)) : Qnil,
    rb_str_new2(return_type ? return_type : ""),
    0);
}

static void
define_operation_delegator(VALUE klass, VALUE target_mod, void *op_handle, VALUE op_info)
{
  VALUE recv;
  ID mid;
  recv = rb_const_get_at(klass, rb_intern("OperationDelegator"));
  mid = rb_intern("define_delegator");
  rb_funcall(recv, mid, 3, target_mod, PTR2NUM(op_handle), op_info);
}

static void
setup_operation(VALUE klass, VALUE name)
{
  void *op_handle;
  char const *name_cstr, *real_name, *description, *key_var_num_args, *return_type;
  char const **arg_names, **arg_type_infos, **arg_descriptions;
  mx_uint num_args;
  VALUE op_info, mod_name, mod, func_name;

  name_cstr = StringValueCStr(name);

  CHECK_CALL(MXNET_API(NNGetOpHandle)(name_cstr, &op_handle)); /* check handle availability just in case */

  CHECK_CALL(MXNET_API(MXSymbolGetAtomicSymbolInfo)(
      op_handle, &real_name, &description,
      &num_args, &arg_names, &arg_type_infos, &arg_descriptions,
      &key_var_num_args, &return_type));

  op_info = op_info_new(name_cstr, real_name, description,
                        num_args, arg_names, arg_type_infos,
                        arg_descriptions, key_var_num_args, return_type);
  mod_name = rb_funcall(op_info, rb_intern("module_name"), 0);
  mod = rb_const_get_at(klass, SYM2ID(mod_name));

  func_name = rb_funcall(op_info, rb_intern("func_name"), 0);
  func_name = rb_sym_to_s(func_name);
  register_handle(mod, RSTRING_PTR(func_name), op_handle);
  register_description(mod, RSTRING_PTR(func_name), op_info);

  define_operation_delegator(klass, mod, op_handle, op_info);
}

static VALUE
list_all_op_names(void)
{
  mx_uint size, i;
  char const** op_names;
  VALUE ary;

  CHECK_CALL(MXNET_API(MXListAllOpNames)(&size, &op_names));
  ary = rb_ary_new_capa((long)size);
  for (i = 0; i < size; ++i) {
    rb_ary_push(ary, rb_str_new2(op_names[i]));
  }

  return ary;
}

void
mxnet_init_operations(VALUE klass)
{
  VALUE mOps, mInternal, mContrib, mLinalg, mSparse;
  long i;
  VALUE op_names;

  mOps = rb_define_module_under(klass, "Ops");
  mInternal = rb_define_module_under(klass, "Internal");
  mContrib = rb_define_module_under(klass, "Contrib");
  mLinalg = rb_define_module_under(klass, "Linalg");
  mSparse = rb_define_module_under(klass, "Sparse");

  mxnet_sOpInfo = rb_const_get_at(mxnet_mMXNet, rb_intern("OpInfo"));
  mxnet_sOpArgInfo = rb_const_get_at(mxnet_mMXNet, rb_intern("OpArgInfo"));

  rb_define_singleton_method(mxnet_sOpInfo, "lookup", lookup_op_info, 2);

  id_handles = rb_intern("handles");
  id_descriptions = rb_intern("descriptions");

  op_names = list_all_op_names();
  for (i = 0; i < RARRAY_LEN(op_names); ++i) {
    setup_operation(klass, RARRAY_AREF(op_names, i));
  }
}
