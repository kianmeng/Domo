defmodule Domo.TypeEnsurerFactory.Resolver.ModuleDepsTest do
  use Domo.FileCase

  alias Domo.TypeEnsurerFactory.Error
  alias Domo.TypeEnsurerFactory.Resolver
  alias Mix.Tasks.Compile.Domo, as: DomoMixTask
  alias ModuleNested.Module.Submodule

  import ResolverTestHelper

  setup [:setup_project_planner]

  defmodule FailingDepsFile do
    def write(path, _content) do
      if String.ends_with?(path, DomoMixTask.deps_manifest()) do
        {:error, :write_error}
      else
        :ok
      end
    end

    def read(_path), do: {:error, :noent}
  end

  describe "TypeEnsurerFactory.Resolver should" do
    test "write deps file and return :ok",
         %{
           planner: planner,
           plan_file: plan_file,
           types_file: types_file,
           deps_file: deps_file
         } do
      plan_types([quote(do: integer)], planner)

      assert :ok == Resolver.resolve(plan_file, types_file, deps_file)
      assert true == File.exists?(deps_file)
    end

    test "return error if can't write deps file", %{
      planner: planner,
      plan_file: plan_file,
      types_file: types_file,
      deps_file: deps_file
    } do
      plan(planner, quote(do: integer))
      keep_env(planner, __ENV__)
      flush(planner)

      assert {:error,
              [
                %Error{
                  compiler_module: Resolver,
                  file: ^deps_file,
                  message: {:deps_manifest_failed, :write_error}
                }
              ]} = Resolver.resolve(plan_file, types_file, deps_file, FailingDepsFile)
    end

    test "write resolved module => {its path, dependency modules list} as value to a deps file",
         %{
           planner: planner,
           plan_file: plan_file,
           types_file: types_file,
           deps_file: deps_file
         } do
      plan(
        planner,
        LocalUserType,
        :remote_field_float,
        quote(context: ModuleNested, do: ModuleNested.mn_float())
      )

      keep_env(planner, LocalUserType, LocalUserType.env())
      flush(planner)

      :ok = Resolver.resolve(plan_file, types_file, deps_file)

      assert %{LocalUserType => {path, [ModuleNested]}} = read_deps(deps_file)
      assert path =~ "/user_types.ex"
    end

    test "write unique dependency modules rejecting duplicates", %{
      planner: planner,
      plan_file: plan_file,
      types_file: types_file,
      deps_file: deps_file
    } do
      plan(
        planner,
        LocalUserType,
        :remote_field_float,
        quote(context: ModuleNested, do: ModuleNested.mn_float())
      )

      plan(
        planner,
        LocalUserType,
        :some_other_field,
        quote(context: ModuleNested, do: ModuleNested.mn_float())
      )

      keep_env(planner, LocalUserType, LocalUserType.env())
      flush(planner)

      :ok = Resolver.resolve(plan_file, types_file, deps_file)

      assert %{LocalUserType => {_path, [ModuleNested]}} = read_deps(deps_file)
    end

    test "Not write module itself as a dependency", %{
      planner: planner,
      plan_file: plan_file,
      types_file: types_file,
      deps_file: deps_file
    } do
      plan(
        planner,
        LocalUserType,
        :i,
        quote(context: LocalUserType, do: LocalUserType.int())
      )

      keep_env(planner, LocalUserType, LocalUserType.env())
      flush(planner)

      :ok = Resolver.resolve(plan_file, types_file, deps_file)

      assert %{} == read_deps(deps_file)
    end

    test "write dependency modules for all planned field types", %{
      planner: planner,
      plan_file: plan_file,
      types_file: types_file,
      deps_file: deps_file
    } do
      plan(
        planner,
        LocalUserType,
        :remote_field_float,
        quote(context: ModuleNested, do: ModuleNested.mn_float())
      )

      plan(
        planner,
        LocalUserType,
        :some_atom,
        quote(context: Submodule, do: Submodule.t())
      )

      plan(
        planner,
        RemoteUserType,
        :some_int,
        quote(context: Submodule, do: Submodule.op())
      )

      keep_env(planner, LocalUserType, LocalUserType.env())
      keep_env(planner, RemoteUserType, RemoteUserType.env())
      flush(planner)

      :ok = Resolver.resolve(plan_file, types_file, deps_file)

      assert %{
               LocalUserType => {local_source_path, [ModuleNested, Submodule]},
               RemoteUserType => {remote_source_path, [Submodule]}
             } = read_deps(deps_file)

      assert local_source_path == remote_source_path
      assert remote_source_path =~ "/user_types.ex"
    end

    test "overwrite deps for a planned module keeping previously resolved module's deps intact",
         %{
           planner: planner,
           plan_file: plan_file,
           types_file: types_file,
           deps_file: deps_file
         } do
      File.write!(
        deps_file,
        :erlang.term_to_binary(%{
          ModuleStoredBefore => {".../module_stored_before.ex", [ModuleNested]},
          AffectedModule => {".../affected_module.ex", [SomeModule]},
          LocalUserType => {".../previous_local_user.ex", [PreviousDep1, PreviousDep2]}
        })
      )

      plan(
        planner,
        LocalUserType,
        :remote_field_float,
        quote(context: ModuleNested, do: ModuleNested.mn_float())
      )

      keep_env(planner, LocalUserType, LocalUserType.env())
      flush(planner)

      :ok = Resolver.resolve(plan_file, types_file, deps_file)

      assert %{
               ModuleStoredBefore => {".../module_stored_before.ex", [ModuleNested]},
               AffectedModule => {".../affected_module.ex", [SomeModule]},
               LocalUserType => {local_source_path, [ModuleNested]}
             } = read_deps(deps_file)

      assert local_source_path =~ "/user_types.ex"
    end

    test "write every intermediate dependency", %{
      planner: planner,
      plan_file: plan_file,
      types_file: types_file,
      deps_file: deps_file
    } do
      plan(
        planner,
        LocalUserType,
        :remote_field_sub_float,
        quote(context: RemoteUserType, do: RemoteUserType.sub_float())
      )

      keep_env(planner, LocalUserType, LocalUserType.env())
      flush(planner)

      :ok = Resolver.resolve(plan_file, types_file, deps_file)

      assert %{
               LocalUserType =>
                 {path,
                  [
                    ModuleNested,
                    ModuleNested.Module,
                    ModuleNested.Module.Submodule,
                    RemoteUserType
                  ]}
             } = read_deps(deps_file)

      assert path =~ "/user_types.ex"
    end
  end
end