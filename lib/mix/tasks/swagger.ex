defmodule Mix.Tasks.Swagger do
  use Mix.Task

  @shortdoc "Generates Swagger JSON from Phoenix routes and Ecto models"

  @moduledoc """
  To use swaggerdoc with your projects, edit your mix.exs file and add it as a dependency:

  ```elixir
  defp deps do
    [{:swaggerdoc, "~> 0.0.1"}]
  end
  ```

  To execute the Mix task, simply type `mix swagger`:

  ```elixir
  hello_user$ mix swagger
  Generating Swagger documentation...
  Adding Ecto definitions...
  Adding Phoenix Routes...
  Writing JSON to file...
  Finished generating Swagger documentation!
  ```

  To view the generated Swagger in [swagger-ui](https://github.com/swagger-api/swagger-ui):

  * In a temp folder, execute a git clone of https://github.com/swagger-api/swagger-ui.git
  * In the browser of your choice, open the file *temp folder*/swagger-ui/dist/index.html
  * In the JSON API input box at the top of the page, paste in the link to the JSON
  * Hit the 'Explore' button

  For a complete example, please see the [examples](https://github.com/OpenAperture/swaggerdoc/tree/master/examples) section.
  """

  # do not include these fields in the generated API path parameters
  @ecto_exclude_fields  Application.get_env(:swaggerdoc, :exclude_parameters, [:id, :inserted_at, :updated_at])

  @doc """
  Mix entrypoint method
  """
  @spec run([any]) :: no_return
  def run(args) do
    Mix.Task.run "compile", args
    generate_docs(args)
  end

  defp generate_docs(args) do
    Mix.Task.run "compile", args

    try do
      Mix.shell.info "Generating Swagger documentation..."

      Mix.shell.info "Adding Ecto definitions..."
      swagger_json = Map.put(__MODULE__.app_json, :definitions, __MODULE__.build_definitions(:code.all_loaded, %{}))

      Mix.shell.info "Adding Phoenix Routes..."
      swagger_json = __MODULE__.add_routes(__MODULE__.get_router(args).__routes__, swagger_json)

      Mix.shell.info "Writing JSON to file..."
      output_path = Application.get_env(:swaggerdoc, :output_path, System.cwd!() <> "/swagger")
      File.mkdir_p!(output_path)

      output_file = Application.get_env(:swaggerdoc, :output_file, "api.json")
      File.write!("#{output_path}/#{output_file}", Poison.encode!(swagger_json))
      Mix.shell.info "Finished generating Swagger documentation!"
    catch
      :exit, code ->
        Mix.shell.error "Failed to generate Swagger documentation:  Exited with code #{inspect code}"
        Mix.shell.error Exception.format_stacktrace(System.stacktrace)
      :throw, value ->
        Mix.shell.error "Failed to generate Swagger documentation:  Throw called with #{inspect value}"
        Mix.shell.error Exception.format_stacktrace(System.stacktrace)
      what, value ->
        Mix.shell.error "Failed to generate Swagger documentation:  Caught #{inspect what} with #{inspect value}"
        Mix.shell.error Exception.format_stacktrace(System.stacktrace)
    end
  end

  @doc """
  Contains the application-specific JSON that forms the base of the Swagger JSON
  """
  @spec app_json :: map
  def app_json, do: %{
    swagger: Application.get_env(:swaggerdoc, :swagger_version, "2.0"),
    info: %{
      version: Application.get_env(:swaggerdoc, :project_version, ""),
      title: Application.get_env(:swaggerdoc, :project_name, ""),
      description: Application.get_env(:swaggerdoc, :project_desc, ""),
      termsOfService: Application.get_env(:swaggerdoc, :project_terms, ""),
      contact: %{
        name: Application.get_env(:swaggerdoc, :project_contact_name, ""),
        email: Application.get_env(:swaggerdoc, :project_contact_email, ""),
        url: Application.get_env(:swaggerdoc, :project_contact_url, ""),
      },
      license: %{
        name: Application.get_env(:swaggerdoc, :project_license_name, ""),
        url: Application.get_env(:swaggerdoc, :project_license_url, ""),
      }
    },
    host: Application.get_env(:swaggerdoc, :host, ""),
    basePath: Application.get_env(:swaggerdoc, :base_path, ""),
    schemes: Application.get_env(:swaggerdoc, :schemes, ["http"]),
    consumes: Application.get_env(:swaggerdoc, :consumes, []),
    produces: Application.get_env(:swaggerdoc, :produces, []),
    definitions: [],
    paths: %{}
  }

  @doc """
  Method to return the Phoenix router, based on args or configuration
  """
  @spec get_router([any]) :: term
  def get_router(args) do
    cond do
      args != nil && length(args) > 0 -> Module.concat("Elixir", Enum.at(args, 0))
      Mix.Project.umbrella? -> Mix.raise "Umbrella applications require an explicit router to be given to Phoenix.routes"
      true -> Module.concat(Mix.Phoenix.base(), "Router")
    end
  end

  @doc """
  Processes the route for collection of Ecto schema if a route action is either
  `POST`, `PUT` or `PATCH`. Otherwise, parses the route path for placeholders.
  """
  @spec process_route(Phoenix.Router.Route.t) :: Map.t
  defp process_route(route) do
    func_name = "swaggerdoc_#{route.opts}"
    if route.plug != nil && Keyword.has_key?(route.plug.__info__(:functions), String.to_atom(func_name)) do
      apply(route.plug, String.to_atom(func_name), [])
    else
      if route.verb in [:put, :post, :patch] do
        model_suffix =
          Module.split(route.plug) |> Enum.at(-1)
        |> String.trim_suffix("Controller")

        # assumes model name is BaseApp.Model
        module = Module.concat([Mix.Phoenix.base, model_suffix])

        # collect schema defintions
        params = Enum.map(collect_schema_defintions(module), &(build_parameter(&1)))
        %{parameters: params}
      else
        parse_default_verb(route.path)
      end
    end

  end

  @doc """
  Method to add Phoenix routes to the Swagger map
  """
  @spec add_routes(list, map) :: map
  def add_routes(nil, swagger), do: swagger
  def add_routes([], swagger), do: swagger
  def add_routes([route | remaining_routes], swagger) do
    pattern = Application.get_env(:swaggerdoc, :route_test_pattern, ~r//)

    if Regex.match?(pattern, route.path) do
      swagger_path = path_from_route(String.split(route.path, "/"), nil)

      path = swagger[:paths][swagger_path]
      if path == nil do
        path = %{}
      end

      verb = process_route(route)

      response_schema = verb[:response_schema]
      verb = Map.delete(verb, :response_schema)

      verb_string = String.downcase("#{route.verb}")
      if verb[:responses] == nil do
        verb = Map.put(verb, :responses, default_responses(verb_string, response_schema))
      end

      if verb[:produces] == nil do
        verb = Map.put(verb, :produces, Application.get_env(:swaggerdoc, :produces, []))
      end

      if verb[:operationId] == nil do
        verb = Map.put(verb, :operationId, "#{route.opts}")
      end

      if verb[:description] == nil do
        verb = Map.put(verb, :description, "")
      end

      path = Map.put(path, verb_string, verb)
      paths = Map.put(swagger[:paths], swagger_path, path)
      add_routes(remaining_routes, Map.put(swagger, :paths, paths))
    else
      add_routes(remaining_routes, swagger)
    end
  end

  @doc """
  Method to add a specific path from the Phoenix routes to the Swagger map.  Paths must enclose params with braces {var},
  rather than :var (http://swagger.io/specification/#pathTemplating)
  """
  @spec path_from_route(list, map) :: map
  def path_from_route([], swagger_path), do: swagger_path
  def path_from_route([path_segment | remaining_segments], swagger_path) do
    path_from_route(remaining_segments, cond do
      path_segment == nil || String.length(path_segment) == 0 -> swagger_path
      swagger_path == nil -> "/#{path_segment}"
      String.first(path_segment) == ":" -> "#{swagger_path}/{#{String.slice(path_segment, 1..String.length(path_segment))}}"
      true -> "#{swagger_path}/#{path_segment}"
    end)
  end

  @doc """
  Method to build the default Swagger verb map, if not specified by the developer
  """
  @spec parse_default_verb(String.t) :: map
  def parse_default_verb(path) do
    parameters = Enum.reduce String.split(path, "/"), [], fn(path_segment, parameters) ->
      if String.first(path_segment) == ":" do
        name = String.slice(path_segment, 1..String.length(path_segment))
        parameters ++ [build_parameter(name)]
      else
        parameters
      end
    end

    %{
       parameters: parameters,
     }
  end

  @doc """
  Returns a parameter object
  """
  @spec build_parameter(String.t, String.t) :: Map.t
  def build_parameter(name, type \\ "string") do
    #http://swagger.io/specification/#parameterObject
    %{
      "name" => (if is_tuple(name), do: elem(name, 0), else: name),
      "in" => "path",
      "description" => "",
      "required" => true,
      #assumes all params named "id" are integers
      "type" => (if name == "id", do: "integer",else: type)
    }
  end

  @doc """
  Method to build the default Swagger response map for a specific verb, if not specified by the developer
  """
  @spec default_responses(String.t, any) :: map
  def default_responses(verb_string, response_schema \\ nil) do
    responses = %{
      "404" => %{"description" => "Resource not found"},
      "401" => %{"description" => "Request is not authorized"},
      "500" => %{"description" => "Internal Server Error"}
    }
    case verb_string do
      "get" ->
        response = %{"description" => "Resource Content"}
        if response_schema != nil do
          response = Map.put(response, "schema", response_schema)
        end
        Map.merge(responses, %{"200" => response})
      "delete" -> Map.merge(responses, %{"204" => %{"description" => "No Content"}})
      "post" -> Map.merge(responses, %{"201" => %{"description" => "Resource created"}, "400" => %{"description" => "Request contains bad values"}})
      "put" -> Map.merge(responses, %{"204" => %{"description" => "No Content"}, "400" => %{"description" => "Request contains bad values"}})
      _ -> responses
    end
  end

  @doc """
  Method to build the Swagger definitions from Ecto models
  """
  @spec build_definitions(list, map) :: map
  def build_definitions([], def_json), do: def_json
  def build_definitions([code_def | remaining_defs], def_json) do
    module = elem(code_def, 0)
    if properties_json = collect_schema_defintions(module) do

      module_json = %{"properties" => properties_json}
      def_json = Map.put(def_json, "#{inspect module}", module_json)
    end

    build_definitions(remaining_defs, def_json)
  end


  @doc """
  Method to gather schema definitions from Ecto models
  """
  @spec collect_schema_defintions(atom) :: Map.t
  def collect_schema_defintions(module, exclude_fields \\ @ecto_exclude_fields) do
    if :erlang.function_exported(module, :__schema__, 1) do
      Enum.reduce module.__schema__(:types), %{}, fn(type, properties_json) ->
        if elem(type, 0) in exclude_fields do
          properties_json
        else
          Map.put(properties_json, "#{elem(type, 0)}", convert_property_type(elem(type, 1)))
        end
      end
    end
  end

  @doc """
  Method to convert an Ecto schema type (https://github.com/elixir-lang/ecto/blob/v1.0.0/lib/ecto/schema.ex#L107-L145)
  into a Swagger property type (http://swagger.io/specification/#dataTypeType)
  """
  @spec convert_property_type(term) :: map
  def convert_property_type(type) do
    case type do
      :id -> %{"type" => "integer", "format" => "int64"}
      :binary_id -> %{"type" => "string", "format" => "binary"}
      :integer -> %{"type" => "integer", "format" => "int64"}
      :float -> %{"type" => "number", "format" => "float"}
      :boolean -> %{"type" => "boolean"}
      :string -> %{"type" => "string"}
      :binary -> %{"type" => "string", "format" => "binary"}
      Ecto.DateTime -> %{"type" => "string", "format" => "date-time"}
      Ecto.Date -> %{"type" => "string", "format" => "date"}
      Ecto.Time -> %{"type" => "string", "format" => "date-time"}
      :uuid -> %{"type" => "string"}
      _ -> %{"type" => "string"}
    end
  end
end
