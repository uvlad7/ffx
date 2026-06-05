# frozen_string_literal: true
require "ffi"

#
# FFX - Transpile Ruby FFI definitions into C extensions with ZJIT hints
#
# Usage in extconf.rb:
#
#   require_relative "ffx"
#   FFX.create_makefile("strlen", File.expand_path("strlen.rb", __dir__))
#
module FFX
=begin
FFI's builtin types are
typedef enum {
    # Supported
    NATIVE_VOID,
    # Supported
    NATIVE_INT8,
    # Supported
    NATIVE_UINT8,
    # Supported
    NATIVE_INT16,
    # Supported
    NATIVE_UINT16,
    # Supported
    NATIVE_INT32,
    # Supported
    NATIVE_UINT32,
    # Supported
    NATIVE_INT64,
    # Supported
    NATIVE_UINT64,
    # Supported
    NATIVE_LONG,
    # Supported
    NATIVE_ULONG,
    # Supported
    NATIVE_FLOAT32,
    # Supported
    NATIVE_FLOAT64,
    # Can be supported, requires more effort
    NATIVE_LONGDOUBLE,
    # Can't be supported without tight FFI integration, but a replacement address-as-integer exists
    NATIVE_POINTER,
    # Probably can be supported, but is very high effort
    NATIVE_FUNCTION,
    # Can't be supported without tight FFI integration
    NATIVE_BUFFER_IN,
    # Can't be supported without tight FFI integration
    NATIVE_BUFFER_OUT,
    # Can't be supported without tight FFI integration
    NATIVE_BUFFER_INOUT,
    # Supported
    NATIVE_BOOL,

    /** An immutable string.  Nul terminated, but only copies in to the native function */
    # Supported
    NATIVE_STRING,

    /** The function takes a variable number of arguments */
    # Can't be supported without the libffi
    NATIVE_VARARGS,

    /** Struct-by-value param or result */
    # Probably can be supported, but is high effort
    NATIVE_STRUCT,

    /** An array type definition */
    # Probably can be supported, but is high effort
    NATIVE_ARRAY,

    /** Custom native type */
    # Probably can be supported, is converted from/to other native types
    NATIVE_MAPPED,
} NativeType;
=end
  TYPES = {
    # FFI uses 'unsigned int' for NATIVE_UINT32, for example, (I guess) because they always match on platforms Ruby runs on
    # I decided to do the same here
    void:       { byte:  0, c_type: "void" },
    int8:       { byte:  1, c_type: "signed char",        to_c: "NUM2INT(%<arg>s)",                   from_c: "INT2NUM(%<arg>s)" },
    uint8:      { byte:  2, c_type: "unsigned char",      to_c: "NUM2UINT(%<arg>s)",                  from_c: "UINT2NUM(%<arg>s)" },
    int16:      { byte:  3, c_type: "signed short",       to_c: "NUM2INT(%<arg>s)",                   from_c: "INT2NUM(%<arg>s)" },
    uint16:     { byte:  4, c_type: "unsigned short",     to_c: "NUM2UINT(%<arg>s)",                  from_c: "UINT2NUM(%<arg>s)" },
    int32:      { byte:  5, c_type: "signed int",         to_c: "NUM2INT(%<arg>s)",                   from_c: "INT2NUM(%<arg>s)" },
    uint32:     { byte:  6, c_type: "unsigned int",       to_c: "NUM2UINT(%<arg>s)",                  from_c: "UINT2NUM(%<arg>s)" },
    int64:      { byte:  7, c_type: "signed long long",   to_c: "NUM2LL(%<arg>s)",                    from_c: "LL2NUM(%<arg>s)" },
    uint64:     { byte:  8, c_type: "signed long long",   to_c: "NUM2ULL(%<arg>s)",                   from_c: "ULL2NUM(%<arg>s)" },
    long:       { byte:  9, c_type: "signed long",        to_c: "NUM2LONG(%<arg>s)",                  from_c: "LONG2NUM(%<arg>s)" },
    ulong:      { byte: 10, c_type: "unsigned long",      to_c: "NUM2ULONG(%<arg>s)",                 from_c: "ULONG2NUM(%<arg>s)" },
    float:      { byte: 11, c_type: "float",              to_c: "(float)NUM2DBL(%<arg>s)",            from_c: "DBL2NUM(%<arg>s)" },
    double:     { byte: 12, c_type: "double",             to_c: "NUM2DBL(%<arg>s)",                   from_c: "DBL2NUM(%<arg>s)" },
    # reserved for long double
    # FFI doesn't accept anything but true/false but I decided to lift this restriction
    bool:       { byte: 19, c_type: "bool",               to_c: "(RTEST(%<arg>s) ? true : false)",    from_c: "(%<arg>s ? Qtrue : Qfalse)" },
    string:     { byte: 20, c_type: "const char *",       to_c: "(NIL_P(%<arg>s) ? NULL : StringValueCStr(%<arg>s))", from_c: "(%<arg>s ? rb_str_new_cstr(%<arg>s) : Qnil)" },
    # Custom ffx-only types
    pointer_as_integer: {
      byte: 25, c_type: "void *",
      to_c: "(void *)(uintptr_t)NUM2ULL(%<arg>s)",
      from_c: "ULL2NUM((unsigned long long)(uintptr_t)%<arg>s)",
      custom: true
    },
    nonnull_string: {
      byte: 26, c_type: "const char *",
      to_c: "StringValueCStr(%<arg>s)",
      from_c: "rb_str_new_cstr(%<arg>s)",
      custom: true
    },
    # I'd also suggest something for NUM2CHR
  }
  FFI_TYPES = TYPES.filter_map do |name, info|
    next if info[:custom]

    [FFI.find_type(name), name]
  end.to_h

  @modules = {}

  module Library
    def self.extended(mod)
      FFX.register_module(mod)
    end

    def ffi_lib(*libs)
      FFX.module_data(self)[:libs].concat(libs.map(&:to_s))
    end

    def attach_function(name, params, ret)
      params = params.map { |p| TYPES.key?(p) ? p : FFI_TYPES.fetch(FFI.find_type(p)) }
      ret = FFI_TYPES.fetch(FFI.find_type(ret)) unless TYPES.key?(ret)
      FFX.module_data(self)[:functions] << { name: name, params: params, ret: ret }
    end
  end

  class << self
    def register_module(mod)
      @modules[mod] = { libs: [], functions: [] }
    end

    def module_data(mod)
      @modules[mod]
    end

    def create_makefile(ext_name, source_file, headers: [])
      @modules = {}
      @headers = Array(headers)

      # Prepend the source directory so the empty ffi.rb stub there
      # shadows the real gem, keeping our FFI::Library recording stub intact
      ext_dir = File.expand_path(File.dirname(source_file))
      $LOAD_PATH.unshift(ext_dir)
      load File.expand_path(source_file)
      $LOAD_PATH.delete(ext_dir)

      if RUBY_ENGINE == "ruby"
        require "mkmf"

        # Write into $srcdir so the Makefile generated by mkmf (whose VPATH
        # points at $srcdir) always finds the source, regardless of whether
        # extconf.rb is being invoked in-place or from a build directory
        # like the one rake-compiler uses.
        File.write(File.join($srcdir, "#{ext_name}.c"), render(ext_name))

        @modules.each_value do |data|
          data[:functions].each do |f|
            abort "missing function: #{f[:name]}" unless have_func(f[:name].to_s, @headers)
          end
        end

        # Call mkmf's create_makefile (not ours)
        MakeMakefile.instance_method(:create_makefile).bind_call(self, ext_name)
      else
        write_rb_makefile(ext_name, source_file)
      end
    end

    private

    def write_rb_makefile(ext_name, source_file)
      require "rbconfig"
      srcdir = File.dirname(File.expand_path(source_file))
      src_basename = File.basename(source_file)

      File.write("Makefile", <<~MAKEFILE)
        SHELL = /bin/sh

        srcdir = #{srcdir}
        INSTALL_DATA = install -c -m 644
        MAKEDIRS = mkdir -p
        RM = rm -f

        target_prefix =
        sitelibdir = #{RbConfig::CONFIG["sitelibdir"]}
        RUBYLIBDIR = $(sitelibdir)$(target_prefix)

        all:

        install:
        \t$(MAKEDIRS) $(RUBYLIBDIR)
        \t$(INSTALL_DATA) $(srcdir)/#{src_basename} $(RUBYLIBDIR)/#{ext_name}.rb

        clean:

        distclean: clean
        \t-$(RM) Makefile

        .PHONY: all install clean distclean
      MAKEFILE
    end

    def render(ext_name)
      c = +"/* Generated by FFX - do not edit */\n"
      c << "#include <ruby.h>\n"
      c << "#include <string.h>\n"
      c << "#include <stdlib.h>\n"
      c << "#include <stdbool.h>\n"
      c << "#include <stdint.h>\n"
      c << "#include <math.h>\n"
      Array(@headers).each { |h| c << "#include <#{h}>\n" }
      c << "\n"

      @modules.each do |mod, data|
        prefix = mod.name.gsub("::", "_").downcase
        data[:functions].each do |f|
          c << render_impl(f, prefix)
          c << render_trampoline(f, prefix)
        end
      end

      c << render_init(ext_name)
    end

    def vparams(f)
      (["VALUE self"] + f[:params].each_index.map { |i| "VALUE arg#{i}" }).join(", ")
    end

    def render_impl(f, prefix)
      name = f[:name]
      ret = f[:ret]
      impl = "rb_#{prefix}_#{name}_impl"

      args = f[:params].each_with_index.map { |t, i|
        format(TYPES.fetch(t)[:to_c], arg: "arg#{i}")
      }.join(", ")
      call = "#{name}(#{args})"

      body = if ret == :void
        "    #{call};\n    return Qnil;\n"
      else
        ret_info = TYPES.fetch(ret)
        "    #{ret_info[:c_type]} ffx_ret = #{call};\n    return #{format(ret_info[:from_c], arg: 'ffx_ret')};\n"
      end

      # Use asm label to force _ prefix on all platforms so the
      # trampoline can always branch to _impl without #ifdef
      out = +"static VALUE #{impl}(#{vparams(f)}) __asm__(\"_#{impl}\");\n\n"
      out << <<~C
        __attribute__((used))
        static VALUE
        #{impl}(#{vparams(f)})
        {
        #{body}}

      C
    end

    def render_trampoline(f, prefix)
      name = f[:name]
      params = f[:params]
      ret = f[:ret]

      pbytes = params.map { |t|
        "  \".byte #{TYPES.fetch(t)[:byte]}\\n\"\n"
      }.join

      <<~C
        __attribute__((naked, aligned(16)))
        static VALUE
        rb_#{prefix}_#{name}(#{vparams(f)})
        {
        __asm__(
          "#{branch_mnemonic} _rb_#{prefix}_#{name}_impl\\n"
          ".long 0x46464930\\n"
          ".byte #{params.size}\\n"
        #{pbytes}  ".byte #{TYPES.fetch(ret)[:byte]}\\n"
          ".asciz \\"#{name}\\"\\n"
        );
        }

      C
    end

    def branch_mnemonic
      case RUBY_PLATFORM
      when /aarch64|arm64/ then "b"
      when /x86_64/        then "jmp"
      else raise "FFX: unsupported architecture: #{RUBY_PLATFORM}"
      end
    end

    def render_init(ext_name)
      out = +""
      out << "void\n"
      out << "Init_#{ext_name}(void)\n"
      out << "{\n"

      @modules.each do |mod, data|
        mn = mod.name
        prefix = mn.gsub("::", "_").downcase

        out << "    VALUE rb_m#{mn} = rb_define_module(\"#{mn}\");\n"

        data[:functions].each do |f|
          out << "    rb_define_module_function(rb_m#{mn}, \"#{f[:name]}\", rb_#{prefix}_#{f[:name]}, #{f[:params].size});\n"
          out << "    rb_define_module_function(rb_m#{mn}, \"#{f[:name]}_c\", rb_#{prefix}_#{f[:name]}_impl, #{f[:params].size});\n"
        end
      end

      out << "}\n"
    end
  end
end

module FFI
  remove_const(:Library)
  Library = FFX::Library
end
