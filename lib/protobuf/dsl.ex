defmodule Protobuf.DSL do
  @doc """
  Define a field in the message module.
  """
  defmacro field(name, fnum, options \\ []) do
    quote do
      @fields {unquote(name), unquote(fnum), unquote(options)}
    end
  end

  @doc """
  Define oneof in the message module.
  """
  defmacro oneof(name, index) do
    quote do
      @oneofs {unquote(name), unquote(index)}
    end
  end

  @doc """
  Define "extend" for a message(the first argument module).
  """
  defmacro extend(mod, name, fnum, options) do
    quote do
      @extends {unquote(mod), unquote(name), unquote(fnum), unquote(options)}
    end
  end

  @doc """
  Define extensions range in the message module to allow extensions for this module.
  """
  defmacro extensions(ranges) do
    quote do
      @extensions unquote(ranges)
    end
  end

  alias Protobuf.FieldProps
  alias Protobuf.MessageProps
  alias Protobuf.Wire

  # Registered as the @before_compile callback for modules that call "use Protobuf".
  defmacro __before_compile__(env) do
    fields = Module.get_attribute(env.module, :fields)
    options = Module.get_attribute(env.module, :options)
    oneofs = Module.get_attribute(env.module, :oneofs)
    extensions = Module.get_attribute(env.module, :extensions)

    extension_props =
      Module.get_attribute(env.module, :extends)
      |> gen_extension_props()

    msg_props = generate_message_props(fields, oneofs, extensions, options)

    defines_t_type? = Module.defines_type?(env.module, {:t, 0})
    defines_defstruct? = Module.defines?(env.module, {:__struct__, 1})

    quote do
      @spec __message_props__() :: Protobuf.MessageProps.t()
      def __message_props__ do
        unquote(Macro.escape(msg_props))
      end

      cond do
        # If both "defstruct" and "@type t()" are called, it's probably okay because it's the code
        # we used to generated before from this library, but we want to get rid of it, so we warn.
        unquote(defines_defstruct?) and unquote(defines_t_type?) and not unquote(msg_props.enum?) ->
          IO.warn("""
          Since v0.10.0 of the :protobuf library, the t/0 type and the struct are automatically \
          generated for modules that call "use Protobuf" if they are Protobuf enums or messages. \
          Remove your explicit definition of both of these or regenerate the files with the \
          latest version of the protoc-gen-elixir plugin. This warning will become an error \
          in version 0.10.0+ of the :protobuf library.\
          """)

        # If users defined only "defstruct" OR "@type t()", it means either they didn't generate
        # the code through this library or they modified the generated files. In either case,
        # let's raise here since we could have inconsistencies between the user-defined spec/type
        # and our type/spec, respectively.
        (unquote(defines_defstruct?) or unquote(defines_t_type?)) and not unquote(msg_props.enum?) ->
          raise """
          since v0.10.0 of the :protobuf library, the t/0 type and the struct are automatically \
          generated for modules that call "use Protobuf" if they are Protobuf enums or messages. \
          In #{inspect(__MODULE__)}, you defined the struct OR the t/0 type. This could cause inconsistencies \
          with the type or struct generated by the library. You can either:

            * make sure that you define both the t/0 type as well as the struct, but that will
              become an error in later versions of the Protobuf library

            * remove both the t/0 type definition as well as the struct definition and let the
              library define both

            * regenerate the file from the Protobuf source definition with the latest version
              of the protoc-gen-elixir plugin, which won't generate the struct or the t/0 type
              definition

          """

        # Newest version of this library generate t/0 for enums.
        unquote(msg_props.enum?) ->
          unquote(def_t_typespec(msg_props, extension_props))

        # Newest version of this library generate both the t/0 type as well as the struct.
        true ->
          unquote(def_t_typespec(msg_props, extension_props))
          unquote(gen_defstruct(msg_props))
      end

      unquote(maybe_def_enum_functions(msg_props, fields))

      if unquote(Macro.escape(extension_props)) != nil do
        def __protobuf_info__(:extension_props) do
          unquote(Macro.escape(extension_props))
        end
      end

      def __protobuf_info__(_) do
        nil
      end

      if unquote(Macro.escape(extensions)) do
        unquote(def_extension_functions())
      end
    end
  end

  defp def_t_typespec(%MessageProps{enum?: true} = props, _extension_props) do
    quote do
      @type t() :: unquote(Protobuf.DSL.Typespecs.quoted_enum_typespec(props))
    end
  end

  defp def_t_typespec(%MessageProps{} = props, _extension_props = nil) do
    quote do
      @type t() :: unquote(Protobuf.DSL.Typespecs.quoted_message_typespec(props))
    end
  end

  defp def_t_typespec(_props, _extension_props) do
    nil
  end

  defp maybe_def_enum_functions(%{syntax: syntax, enum?: true, field_props: props}, fields) do
    if syntax == :proto3 do
      unless props[0], do: raise("The first enum value must be zero in proto3")
    end

    num_to_atom = for {fnum, %{name_atom: name_atom}} <- props, do: {fnum, name_atom}
    atom_to_num = for {name_atom, fnum, _opts} <- fields, do: {name_atom, fnum}, into: %{}

    reverse_mapping =
      for {name_atom, field_number, _opts} <- fields,
          key <- [field_number, Atom.to_string(name_atom)],
          into: %{},
          do: {key, name_atom}

    Enum.map(atom_to_num, fn {name_atom, fnum} ->
      quote do
        def value(unquote(name_atom)), do: unquote(fnum)
      end
    end) ++
      [
        quote do
          def value(v) when is_integer(v), do: v
        end
      ] ++
      Enum.map(num_to_atom, fn {fnum, name_atom} ->
        quote do
          def key(unquote(fnum)), do: unquote(name_atom)
        end
      end) ++
      [
        quote do
          def key(int) when is_integer(int), do: int
        end,
        quote do
          def mapping(), do: unquote(Macro.escape(atom_to_num))
        end,
        quote do
          def __reverse_mapping__(), do: unquote(Macro.escape(reverse_mapping))
        end
      ]
  end

  defp maybe_def_enum_functions(_, _), do: nil

  defp def_extension_functions() do
    quote do
      def put_extension(%{} = map, extension_mod, field, value) do
        Protobuf.Extension.put(__MODULE__, map, extension_mod, field, value)
      end

      def get_extension(struct, extension_mod, field, default \\ nil) do
        Protobuf.Extension.get(struct, extension_mod, field, default)
      end
    end
  end

  defp generate_message_props(fields, oneofs, extensions, options) do
    syntax = Keyword.get(options, :syntax, :proto2)

    field_props =
      Map.new(fields, fn {name, fnum, opts} -> {fnum, field_props(syntax, name, fnum, opts)} end)

    # The "reverse" of field props, that is, a map from atom name to field number.
    field_tags =
      Map.new(field_props, fn {fnum, %FieldProps{name_atom: name_atom}} -> {name_atom, fnum} end)

    repeated_fields =
      for {_fnum, %FieldProps{repeated?: true, name_atom: name}} <- field_props,
          do: name

    embedded_fields =
      for {_fnum, %FieldProps{embedded?: true, map?: false, name_atom: name}} <- field_props,
          do: name

    %MessageProps{
      tags_map: Map.new(fields, fn {_, fnum, _} -> {fnum, fnum} end),
      ordered_tags: field_props |> Map.keys() |> Enum.sort(),
      field_props: field_props,
      field_tags: field_tags,
      repeated_fields: repeated_fields,
      embedded_fields: embedded_fields,
      syntax: syntax,
      oneof: Enum.reverse(oneofs),
      enum?: Keyword.get(options, :enum) == true,
      map?: Keyword.get(options, :map) == true,
      extension_range: extensions
    }
  end

  defp gen_extension_props([_ | _] = extends) do
    extensions =
      Map.new(extends, fn {extendee, name_atom, fnum, opts} ->
        # Only proto2 has extensions
        props = field_props(:proto2, name_atom, fnum, opts)

        props = %Protobuf.Extension.Props.Extension{
          extendee: extendee,
          field_props: props
        }

        {{extendee, fnum}, props}
      end)

    name_to_tag =
      Map.new(extends, fn {extendee, name_atom, fnum, _opts} ->
        {{extendee, name_atom}, {extendee, fnum}}
      end)

    %Protobuf.Extension.Props{extensions: extensions, name_to_tag: name_to_tag}
  end

  defp gen_extension_props(_) do
    nil
  end

  defp field_props(syntax, name, fnum, opts) do
    %FieldProps{
      fnum: fnum,
      name: Atom.to_string(name),
      name_atom: name
    }
    |> parse_field_opts_to_field_props(opts)
    |> verify_no_default_in_proto3(syntax)
    |> wrap_enum_type()
    |> cal_label(syntax)
    |> cal_json_name()
    |> cal_embedded()
    |> cal_packed(syntax)
    |> cal_repeated()
    |> cal_encoded_fnum()
  end

  defp parse_field_opts_to_field_props(%FieldProps{} = props, opts) do
    Enum.reduce(opts, props, fn
      {:optional, optional?}, acc -> %FieldProps{acc | optional?: optional?}
      {:required, required?}, acc -> %FieldProps{acc | required?: required?}
      {:enum, enum?}, acc -> %FieldProps{acc | enum?: enum?}
      {:map, map?}, acc -> %FieldProps{acc | map?: map?}
      {:repeated, repeated?}, acc -> %FieldProps{acc | repeated?: repeated?}
      {:embedded, embedded}, acc -> %FieldProps{acc | embedded?: embedded}
      {:deprecated, deprecated?}, acc -> %FieldProps{acc | deprecated?: deprecated?}
      {:packed, packed?}, acc -> %FieldProps{acc | packed?: packed?}
      {:type, type}, acc -> %FieldProps{acc | type: type}
      {:default, default}, acc -> %FieldProps{acc | default: default}
      {:oneof, oneof}, acc -> %FieldProps{acc | oneof: oneof}
      {:json_name, json_name}, acc -> %FieldProps{acc | json_name: json_name}
    end)
  end

  defp cal_label(%FieldProps{} = props, :proto3) do
    if props.required? do
      raise Protobuf.InvalidError, message: "required can't be used in proto3"
    else
      %FieldProps{props | optional?: true}
    end
  end

  defp cal_label(props, _syntax), do: props

  defp wrap_enum_type(%FieldProps{enum?: true, type: type} = props) do
    %FieldProps{props | type: {:enum, type}, wire_type: Wire.wire_type({:enum, type})}
  end

  defp wrap_enum_type(%FieldProps{type: type} = props) do
    %FieldProps{props | wire_type: Wire.wire_type(type)}
  end

  # The compiler always emits a json name, but we omit it in the DSL when it
  # matches the name, to keep it uncluttered. Now we infer it back from name.
  defp cal_json_name(%FieldProps{json_name: name} = props) when is_binary(name), do: props
  defp cal_json_name(props), do: %FieldProps{props | json_name: props.name}

  defp verify_no_default_in_proto3(%FieldProps{} = props, syntax) do
    if syntax == :proto3 and not is_nil(props.default) do
      raise Protobuf.InvalidError, message: "default can't be used in proto3"
    else
      props
    end
  end

  defp cal_embedded(%FieldProps{type: type, enum?: false} = props) when is_atom(type) do
    case to_string(type) do
      "Elixir." <> _ -> %FieldProps{props | embedded?: true}
      _ -> props
    end
  end

  defp cal_embedded(props), do: props

  defp cal_packed(%FieldProps{packed?: true, repeated?: repeated?} = props, _syntax) do
    cond do
      props.embedded? -> raise ":packed can't be used with :embedded field"
      repeated? -> %FieldProps{props | packed?: true}
      true -> raise ":packed must be used with :repeated"
    end
  end

  defp cal_packed(%FieldProps{packed?: false} = props, _syntax) do
    props
  end

  defp cal_packed(%FieldProps{type: type, repeated?: true} = props, :proto3) do
    packed? = (props.enum? or not props.embedded?) and type_numeric?(type)
    %FieldProps{props | packed?: packed?}
  end

  defp cal_packed(props, _syntax), do: %FieldProps{props | packed?: false}

  defp cal_repeated(%FieldProps{map?: true} = props), do: %FieldProps{props | repeated?: false}

  defp cal_repeated(%FieldProps{repeated?: true, oneof: oneof}) when not is_nil(oneof),
    do: raise(":oneof can't be used with repeated")

  defp cal_repeated(props), do: props

  defp cal_encoded_fnum(%FieldProps{fnum: fnum, packed?: true} = props) do
    encoded_fnum = Protobuf.Encoder.encode_fnum(fnum, Wire.wire_type(:bytes))
    %FieldProps{props | encoded_fnum: encoded_fnum}
  end

  defp cal_encoded_fnum(%FieldProps{fnum: fnum, wire_type: wire_type} = props) do
    encoded_fnum = Protobuf.Encoder.encode_fnum(fnum, wire_type)
    %FieldProps{props | encoded_fnum: encoded_fnum}
  end

  defp gen_defstruct(%MessageProps{} = message_props) do
    regular_fields =
      for {_fnum, %FieldProps{oneof: nil} = prop} <- message_props.field_props,
          do: {prop.name_atom, field_default(message_props.syntax, prop)}

    oneof_fields =
      for {name_atom, _fnum} <- message_props.oneof,
          do: {name_atom, _struct_default = nil}

    extension_fields =
      if message_props.extension_range do
        [{:__pb_extensions__, _default = %{}}]
      else
        []
      end

    unknown_fields = {:__unknown_fields__, _default = []}

    struct_fields = regular_fields ++ oneof_fields ++ extension_fields ++ [unknown_fields]

    quote do
      defstruct unquote(Macro.escape(struct_fields))
    end
  end

  defp type_numeric?(:int32), do: true
  defp type_numeric?(:int64), do: true
  defp type_numeric?(:uint32), do: true
  defp type_numeric?(:uint64), do: true
  defp type_numeric?(:sint32), do: true
  defp type_numeric?(:sint64), do: true
  defp type_numeric?(:bool), do: true
  defp type_numeric?({:enum, _}), do: true
  defp type_numeric?(:fixed32), do: true
  defp type_numeric?(:sfixed32), do: true
  defp type_numeric?(:fixed64), do: true
  defp type_numeric?(:sfixed64), do: true
  defp type_numeric?(:float), do: true
  defp type_numeric?(:double), do: true
  defp type_numeric?(_), do: false

  # Used by Protobuf.Decoder
  @doc false
  def field_default(syntax, field_props)

  def field_default(_syntax, %FieldProps{default: default}) when not is_nil(default), do: default
  def field_default(_syntax, %FieldProps{repeated?: true}), do: []
  def field_default(_syntax, %FieldProps{map?: true}), do: %{}
  def field_default(:proto3, props), do: type_default(props.type)
  def field_default(_syntax, _props), do: nil

  defp type_default(:int32), do: 0
  defp type_default(:int64), do: 0
  defp type_default(:uint32), do: 0
  defp type_default(:uint64), do: 0
  defp type_default(:sint32), do: 0
  defp type_default(:sint64), do: 0
  defp type_default(:bool), do: false
  defp type_default({:enum, mod}), do: Code.ensure_loaded?(mod) && mod.key(0)
  defp type_default(:fixed32), do: 0
  defp type_default(:sfixed32), do: 0
  defp type_default(:fixed64), do: 0
  defp type_default(:sfixed64), do: 0
  defp type_default(:float), do: 0.0
  defp type_default(:double), do: 0.0
  defp type_default(:bytes), do: <<>>
  defp type_default(:string), do: ""
  defp type_default(:message), do: nil
  defp type_default(:group), do: nil
  defp type_default(_), do: nil
end
