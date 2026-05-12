defmodule SvPortSim.Verilator.Wrapper.Trace do
  @moduledoc false

  @type mode :: false | :vcd | :fst

  @spec normalize(term()) :: {:ok, map()} | {:error, term()}
  def normalize(false), do: {:ok, disabled()}
  def normalize(nil), do: {:ok, disabled()}

  def normalize(:vcd) do
    {:ok,
     enabled(%{
       mode: :vcd,
       include: ~s(#include "verilated_vcd_c.h"\n),
       type: "VerilatedVcdC",
       default_path: "trace.vcd",
       verilator_args: ["--trace-vcd"]
     })}
  end

  def normalize(:fst) do
    {:ok,
     enabled(%{
       mode: :fst,
       include: ~s(#include "verilated_fst_c.h"\n),
       type: "VerilatedFstC",
       default_path: "trace.fst",
       verilator_args: ["--trace-fst"]
     })}
  end

  def normalize(other), do: {:error, {:unsupported_trace_mode, other}}

  @spec verilator_args(mode()) :: {:ok, [String.t()]} | {:error, term()}
  def verilator_args(mode) do
    with {:ok, trace} <- normalize(mode) do
      {:ok, trace.verilator_args}
    end
  end

  defp disabled do
    %{
      enabled?: false,
      mode: false,
      include: "",
      type: "",
      default_path: "",
      verilator_args: [],
      helpers: "",
      ctor_init: "",
      ctor_body: "",
      members: "",
      dump_call: "",
      close_call: ""
    }
  end

  defp enabled(
         %{
           include: include,
           type: type,
           default_path: default_path,
           verilator_args: verilator_args
         } = opts
       ) do
    %{
      enabled?: true,
      mode: opts.mode,
      include: include,
      type: type,
      default_path: default_path,
      verilator_args: verilator_args,
      helpers: helpers(default_path),
      ctor_init: ", trace_enabled_(false)",
      ctor_body: ctor_body(type),
      members: members(type),
      dump_call: "dump_trace();",
      close_call: "close_trace();"
    }
  end

  defp helpers(default_path) do
    """
    struct TraceOptions {
      bool enabled = false;
      std::string path = #{cpp_string(default_path)};
    };

    TraceOptions parse_trace_options(int argc, char** argv) {
      TraceOptions options;

      for (int index = 1; index < argc; ++index) {
        const std::string arg(argv[index]);

        if (arg == "+svps_trace") {
          options.enabled = true;
        } else if (arg.rfind("+svps_trace_file=", 0) == 0) {
          options.enabled = true;
          options.path = arg.substr(std::string("+svps_trace_file=").size());
        }
      }

      return options;
    }
    """
  end

  defp ctor_body(type) do
    """
    const TraceOptions trace_options = parse_trace_options(argc, argv);
    if (trace_options.enabled) {
      Verilated::traceEverOn(true);
      tracep_.reset(new #{type});
      top_->trace(tracep_.get(), 99);
      tracep_->open(trace_options.path.c_str());
      trace_enabled_ = true;
      dump_trace();
    }
    """
  end

  defp members(type) do
    """
    std::unique_ptr<#{type}> tracep_;
    bool trace_enabled_;

    void dump_trace() {
      if (trace_enabled_ && tracep_) {
        tracep_->dump(contextp_->time());
      }
    }

    void close_trace() {
      if (tracep_) {
        tracep_->close();
        tracep_.reset();
      }
      trace_enabled_ = false;
    }
    """
  end

  defp cpp_string(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    ~s("#{escaped}")
  end
end
