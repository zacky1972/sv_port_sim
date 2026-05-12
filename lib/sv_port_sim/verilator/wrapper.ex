defmodule SvPortSim.Verilator.Wrapper do
  @moduledoc """
  Builds interactive C++ wrapper files for Verilated SystemVerilog top modules.

  The generated executable creates one `VerilatedContext` and one
  Verilator-generated top-module instance before entering the command loop. The
  same simulation session is reused for every protocol request until `stop`,
  `shutdown`, EOF, or a fatal wrapper/protocol failure terminates the process.

  The `top_module` argument is the SystemVerilog top-module name without
  Verilator's `V` class-name prefix. For example, `"Counter"` maps to the
  Verilator-generated class `VCounter` and to the wrapper file
  `Counter_wrapper.cpp`.

  Accepted top-module names are limited to a safe identifier subset: the name
  must start with an ASCII letter or underscore, followed by ASCII letters,
  digits, underscores, or dollar signs.
  """

  @sv_identifier ~r/\A[A-Za-z_][A-Za-z0-9_$]*\z/

  @wrapper_template ~S"""
  #include "@@VERILATED_CLASS@@.h"
  #include "verilated.h"

  #include <cctype>
  #include <cstdio>
  #include <cstdint>
  #include <exception>
  #include <iostream>
  #include <limits>
  #include <memory>
  #include <sstream>
  #include <string>

  #ifdef _WIN32
  #include <fcntl.h>
  #include <io.h>
  #endif

  namespace {

  constexpr std::uint32_t kProtocolVersion = 1;
  constexpr std::uint32_t kMaxPayloadSize = 1024 * 1024;
  const char* kTopModule = "@@TOP_MODULE@@";

  struct Request {
    std::uint64_t id = 0;
    std::uint32_t version = 0;
    std::string kind;
    std::string op = "protocol";
    std::string body_json = "{}";
    bool has_id = false;
    bool has_op = false;
  };

  struct FrameRead {
    enum Status { ok, eof, fatal } status;
    std::string payload;
    std::string message;

    static FrameRead Ok(const std::string& payload) {
      FrameRead result;
      result.status = ok;
      result.payload = payload;
      return result;
    }

    static FrameRead Eof() {
      FrameRead result;
      result.status = eof;
      return result;
    }

    static FrameRead Fatal(const std::string& message) {
      FrameRead result;
      result.status = fatal;
      result.message = message;
      return result;
    }
  };

  struct DispatchResult {
    std::string payload;
    bool stop = false;
    int exit_code = 0;
  };

  void set_binary_stdio() {
  #ifdef _WIN32
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
  #endif
  }

  std::string json_escape(const std::string& value) {
    std::ostringstream out;

    for (std::string::const_iterator it = value.begin(); it != value.end(); ++it) {
      const unsigned char ch = static_cast<unsigned char>(*it);

      switch (ch) {
      case '"':
        out << "\\\"";
        break;
      case '\\':
        out << "\\\\";
        break;
      case '\b':
        out << "\\b";
        break;
      case '\f':
        out << "\\f";
        break;
      case '\n':
        out << "\\n";
        break;
      case '\r':
        out << "\\r";
        break;
      case '\t':
        out << "\\t";
        break;
      default:
        if (ch < 0x20) {
          static const char* hex = "0123456789abcdef";
          out << "\\u00" << hex[(ch >> 4) & 0x0f] << hex[ch & 0x0f];
        } else {
          out << static_cast<char>(ch);
        }
        break;
      }
    }

    return out.str();
  }

  std::string json_quote(const std::string& value) {
    return "\"" + json_escape(value) + "\"";
  }

  std::string json_detail(const std::string& key, const std::string& value) {
    return "{" + json_quote(key) + ":" + json_quote(value) + "}";
  }

  class JsonCursor {
  public:
    explicit JsonCursor(const std::string& text) : text_(text), pos_(0) {}

    bool consume(char expected) {
      skip_ws();
      return consume_raw(expected);
    }

    bool parse_string(std::string& value) {
      skip_ws();

      if (!consume_raw('"')) {
        return false;
      }

      std::ostringstream out;

      while (pos_ < text_.size()) {
        const unsigned char ch = static_cast<unsigned char>(text_[pos_++]);

        if (ch == '"') {
          value = out.str();
          return true;
        }

        if (ch < 0x20) {
          return false;
        }

        if (ch != '\\') {
          out << static_cast<char>(ch);
          continue;
        }

        if (pos_ >= text_.size()) {
          return false;
        }

        const char escaped = text_[pos_++];

        switch (escaped) {
        case '"':
        case '\\':
        case '/':
          out << escaped;
          break;
        case 'b':
          out << '\b';
          break;
        case 'f':
          out << '\f';
          break;
        case 'n':
          out << '\n';
          break;
        case 'r':
          out << '\r';
          break;
        case 't':
          out << '\t';
          break;
        case 'u': {
          std::uint32_t code_point = 0;

          if (!parse_unicode_escape(code_point)) {
            return false;
          }

          out << (code_point <= 0x7f ? static_cast<char>(code_point) : '?');
          break;
        }
        default:
          return false;
        }
      }

      return false;
    }

    bool parse_uint64(std::uint64_t& value) {
      skip_ws();

      if (pos_ >= text_.size() || !std::isdigit(static_cast<unsigned char>(text_[pos_]))) {
        return false;
      }

      std::uint64_t parsed = 0;

      if (text_[pos_] == '0') {
        ++pos_;
      } else {
        while (pos_ < text_.size() && std::isdigit(static_cast<unsigned char>(text_[pos_]))) {
          const std::uint64_t digit = static_cast<std::uint64_t>(text_[pos_] - '0');

          if (parsed > (std::numeric_limits<std::uint64_t>::max() - digit) / 10) {
            return false;
          }

          parsed = parsed * 10 + digit;
          ++pos_;
        }
      }

      if (pos_ < text_.size()) {
        const char next = text_[pos_];

        if (std::isdigit(static_cast<unsigned char>(next)) || next == '.' || next == 'e' || next == 'E') {
          return false;
        }
      }

      value = parsed;
      return true;
    }

    bool capture_object_value(std::string& object_json) {
      skip_ws();

      if (pos_ >= text_.size() || text_[pos_] != '{') {
        return false;
      }

      const std::size_t start = pos_;

      if (!skip_object()) {
        return false;
      }

      object_json = text_.substr(start, pos_ - start);
      return true;
    }

    bool skip_value() {
      skip_ws();

      if (pos_ >= text_.size()) {
        return false;
      }

      switch (text_[pos_]) {
      case '"': {
        std::string ignored;
        return parse_string(ignored);
      }
      case '{':
        return skip_object();
      case '[':
        return skip_array();
      case 't':
        return consume_literal("true");
      case 'f':
        return consume_literal("false");
      case 'n':
        return consume_literal("null");
      default:
        if (text_[pos_] == '-' || std::isdigit(static_cast<unsigned char>(text_[pos_]))) {
          return skip_number();
        }
        return false;
      }
    }

    bool at_end() {
      skip_ws();
      return pos_ == text_.size();
    }

  private:
    void skip_ws() {
      while (pos_ < text_.size() && std::isspace(static_cast<unsigned char>(text_[pos_]))) {
        ++pos_;
      }
    }

    bool consume_raw(char expected) {
      if (pos_ < text_.size() && text_[pos_] == expected) {
        ++pos_;
        return true;
      }

      return false;
    }

    bool consume_literal(const std::string& literal) {
      if (text_.compare(pos_, literal.size(), literal) != 0) {
        return false;
      }

      pos_ += literal.size();
      return true;
    }

    bool parse_unicode_escape(std::uint32_t& code_point) {
      code_point = 0;

      for (int i = 0; i < 4; ++i) {
        if (pos_ >= text_.size() || !is_hex(static_cast<unsigned char>(text_[pos_]))) {
          return false;
        }

        code_point = (code_point << 4) | hex_value(static_cast<unsigned char>(text_[pos_]));
        ++pos_;
      }

      return true;
    }

    bool skip_object() {
      if (!consume('{')) {
        return false;
      }

      if (consume('}')) {
        return true;
      }

      while (true) {
        std::string key;

        if (!parse_string(key) || !consume(':') || !skip_value()) {
          return false;
        }

        if (consume('}')) {
          return true;
        }

        if (!consume(',')) {
          return false;
        }
      }
    }

    bool skip_array() {
      if (!consume('[')) {
        return false;
      }

      if (consume(']')) {
        return true;
      }

      while (true) {
        if (!skip_value()) {
          return false;
        }

        if (consume(']')) {
          return true;
        }

        if (!consume(',')) {
          return false;
        }
      }
    }

    bool skip_number() {
      if (pos_ < text_.size() && text_[pos_] == '-') {
        ++pos_;
      }

      if (pos_ >= text_.size()) {
        return false;
      }

      if (text_[pos_] == '0') {
        ++pos_;
      } else if (text_[pos_] >= '1' && text_[pos_] <= '9') {
        while (pos_ < text_.size() && std::isdigit(static_cast<unsigned char>(text_[pos_]))) {
          ++pos_;
        }
      } else {
        return false;
      }

      if (pos_ < text_.size() && text_[pos_] == '.') {
        ++pos_;

        if (pos_ >= text_.size() || !std::isdigit(static_cast<unsigned char>(text_[pos_]))) {
          return false;
        }

        while (pos_ < text_.size() && std::isdigit(static_cast<unsigned char>(text_[pos_]))) {
          ++pos_;
        }
      }

      if (pos_ < text_.size() && (text_[pos_] == 'e' || text_[pos_] == 'E')) {
        ++pos_;

        if (pos_ < text_.size() && (text_[pos_] == '+' || text_[pos_] == '-')) {
          ++pos_;
        }

        if (pos_ >= text_.size() || !std::isdigit(static_cast<unsigned char>(text_[pos_]))) {
          return false;
        }

        while (pos_ < text_.size() && std::isdigit(static_cast<unsigned char>(text_[pos_]))) {
          ++pos_;
        }
      }

      return true;
    }

    bool is_hex(unsigned char ch) const {
      return (ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F');
    }

    std::uint32_t hex_value(unsigned char ch) const {
      if (ch >= '0' && ch <= '9') {
        return static_cast<std::uint32_t>(ch - '0');
      }

      if (ch >= 'a' && ch <= 'f') {
        return static_cast<std::uint32_t>(10 + ch - 'a');
      }

      return static_cast<std::uint32_t>(10 + ch - 'A');
    }

    const std::string& text_;
    std::size_t pos_;
  };

  bool find_uint_field(
      const std::string& object_json,
      const std::string& field_name,
      std::uint64_t& value,
      bool& found,
      std::string& error) {
    found = false;
    JsonCursor json(object_json);

    if (!json.consume('{')) {
      error = "body must be a JSON object";
      return false;
    }

    if (json.consume('}')) {
      return true;
    }

    while (true) {
      std::string field;

      if (!json.parse_string(field) || !json.consume(':')) {
        error = "invalid JSON object field";
        return false;
      }

      if (field == field_name) {
        if (found) {
          error = "duplicate field: " + field_name;
          return false;
        }

        if (!json.parse_uint64(value)) {
          error = "field must be a non-negative integer: " + field_name;
          return false;
        }

        found = true;
      } else if (!json.skip_value()) {
        error = "invalid JSON value";
        return false;
      }

      if (json.consume('}')) {
        break;
      }

      if (!json.consume(',')) {
        error = "expected JSON object separator";
        return false;
      }
    }

    if (!json.at_end()) {
      error = "trailing data after JSON object";
      return false;
    }

    return true;
  }

  bool parse_request(const std::string& payload, Request& request, std::string& error) {
    JsonCursor json(payload);
    bool seen_version = false;
    bool seen_id = false;
    bool seen_kind = false;
    bool seen_op = false;
    bool seen_body = false;

    if (!json.consume('{')) {
      error = "payload must be a JSON object";
      return false;
    }

    if (json.consume('}')) {
      error = "missing or invalid protocol version";
      return false;
    }

    while (true) {
      std::string field;

      if (!json.parse_string(field)) {
        error = "invalid JSON object field";
        return false;
      }

      if (!json.consume(':')) {
        error = "missing JSON field separator";
        return false;
      }

      if (field == "v") {
        std::uint64_t parsed_version = 0;

        if (seen_version || !json.parse_uint64(parsed_version) || parsed_version > std::numeric_limits<std::uint32_t>::max()) {
          error = "missing or invalid protocol version";
          return false;
        }

        request.version = static_cast<std::uint32_t>(parsed_version);
        seen_version = true;
      } else if (field == "id") {
        std::uint64_t parsed_id = 0;

        if (seen_id || !json.parse_uint64(parsed_id)) {
          error = "missing or invalid request id";
          return false;
        }

        request.id = parsed_id;
        request.has_id = true;
        seen_id = true;
      } else if (field == "kind") {
        std::string parsed_kind;

        if (seen_kind || !json.parse_string(parsed_kind) || parsed_kind.empty()) {
          error = "missing or invalid message kind";
          return false;
        }

        request.kind = parsed_kind;
        seen_kind = true;
      } else if (field == "op") {
        std::string parsed_op;

        if (seen_op || !json.parse_string(parsed_op) || parsed_op.empty()) {
          error = "missing or invalid operation";
          return false;
        }

        request.op = parsed_op;
        request.has_op = true;
        seen_op = true;
      } else if (field == "body") {
        if (seen_body || !json.capture_object_value(request.body_json)) {
          error = "missing or invalid body object";
          return false;
        }

        seen_body = true;
      } else if (!json.skip_value()) {
        error = "invalid JSON value";
        return false;
      }

      if (json.consume('}')) {
        break;
      }

      if (!json.consume(',')) {
        error = "expected JSON object separator";
        return false;
      }
    }

    if (!json.at_end()) {
      error = "trailing data after JSON envelope";
      return false;
    }

    if (!seen_version) {
      error = "missing or invalid protocol version";
      return false;
    }

    if (!seen_id) {
      error = "missing or invalid request id";
      return false;
    }

    if (!seen_kind) {
      error = "missing or invalid message kind";
      return false;
    }

    if (!seen_op) {
      error = "missing or invalid operation";
      return false;
    }

    if (!seen_body) {
      error = "missing or invalid body object";
      return false;
    }

    return true;
  }

  FrameRead read_frame() {
    unsigned char header[4] = {0, 0, 0, 0};
    std::cin.read(reinterpret_cast<char*>(header), 4);
    const std::streamsize header_bytes = std::cin.gcount();

    if (header_bytes == 0 && std::cin.eof()) {
      return FrameRead::Eof();
    }

    if (header_bytes != 4) {
      return FrameRead::Fatal("truncated frame length");
    }

    const std::uint32_t length =
        (static_cast<std::uint32_t>(header[0]) << 24) |
        (static_cast<std::uint32_t>(header[1]) << 16) |
        (static_cast<std::uint32_t>(header[2]) << 8) |
        static_cast<std::uint32_t>(header[3]);

    if (length == 0) {
      return FrameRead::Fatal("empty payload");
    }

    if (length > kMaxPayloadSize) {
      std::ostringstream message;
      message << "payload too large: " << length << " bytes";
      return FrameRead::Fatal(message.str());
    }

    std::string payload(length, '\0');
    std::cin.read(&payload[0], static_cast<std::streamsize>(length));

    if (std::cin.gcount() != static_cast<std::streamsize>(length)) {
      return FrameRead::Fatal("truncated payload");
    }

    return FrameRead::Ok(payload);
  }

  bool write_frame(const std::string& payload) {
    if (payload.empty() || payload.size() > kMaxPayloadSize) {
      return false;
    }

    const std::uint32_t length = static_cast<std::uint32_t>(payload.size());
    const unsigned char header[4] = {
        static_cast<unsigned char>((length >> 24) & 0xff),
        static_cast<unsigned char>((length >> 16) & 0xff),
        static_cast<unsigned char>((length >> 8) & 0xff),
        static_cast<unsigned char>(length & 0xff)};

    std::cout.write(reinterpret_cast<const char*>(header), 4);
    std::cout.write(payload.data(), static_cast<std::streamsize>(payload.size()));
    std::cout.flush();
    return !std::cout.fail();
  }

  std::string response_envelope(std::uint64_t id, const std::string& op, const std::string& body_json) {
    std::ostringstream out;
    out << "{\"v\":" << kProtocolVersion
        << ",\"id\":" << id
        << ",\"kind\":\"response\""
        << ",\"op\":" << json_quote(op)
        << ",\"body\":" << body_json
        << "}";
    return out.str();
  }

  std::string error_envelope(
      std::uint64_t id,
      const std::string& op,
      const std::string& code,
      const std::string& message,
      const std::string& details_json,
      bool fatal) {
    std::ostringstream out;
    out << "{\"v\":" << kProtocolVersion
        << ",\"id\":" << id
        << ",\"kind\":\"error\""
        << ",\"op\":" << json_quote(op)
        << ",\"body\":{";
    out << "\"code\":" << json_quote(code)
        << ",\"message\":" << json_quote(message)
        << ",\"details\":" << details_json
        << ",\"fatal\":" << (fatal ? "true" : "false")
        << "}}";
    return out.str();
  }

  std::string protocol_error_payload(const Request& request, const std::string& message) {
    return error_envelope(
        request.has_id ? request.id : 0,
        request.has_op ? request.op : "protocol",
        "protocol_error",
        "protocol error",
        json_detail("reason", message),
        true);
  }

  DispatchResult respond(const Request& request, const std::string& body_json) {
    DispatchResult result;
    result.payload = response_envelope(request.id, request.op, body_json);
    return result;
  }

  DispatchResult error_response(
      const Request& request,
      const std::string& code,
      const std::string& message,
      const std::string& details_json,
      bool fatal,
      int exit_code = 1) {
    DispatchResult result;
    result.payload = error_envelope(request.id, request.op, code, message, details_json, fatal);
    result.stop = fatal;
    result.exit_code = fatal ? exit_code : 0;
    return result;
  }

  class SimulationSession {
  public:
    SimulationSession(int argc, char** argv)
        : contextp_(new VerilatedContext), top_(nullptr), finalized_(false) {
      contextp_->commandArgs(argc, argv);
      top_.reset(new @@VERILATED_CLASS@@{contextp_.get()});
    }

    ~SimulationSession() { final(); }

    void eval() { top_->eval(); }

    void advance_cycles(std::uint64_t cycles) {
      for (std::uint64_t cycle = 0; cycle < cycles; ++cycle) {
        contextp_->timeInc(1);
        top_->eval();
      }
    }

    void final() {
      if (!finalized_) {
        top_->final();
        finalized_ = true;
      }
    }

    bool finished() const { return contextp_->gotFinish(); }

    std::uint64_t time() const { return static_cast<std::uint64_t>(contextp_->time()); }

  private:
    std::unique_ptr<VerilatedContext> contextp_;
    std::unique_ptr<@@VERILATED_CLASS@@> top_;
    bool finalized_;
  };

  int finish_session(SimulationSession& session, int exit_code) {
    session.final();
    return exit_code;
  }

  class CommandDispatcher {
  public:
    explicit CommandDispatcher(SimulationSession& session) : session_(session) {}

    DispatchResult dispatch(const Request& request) {
      if (request.version != kProtocolVersion) {
        return error_response(request, "protocol_error", "unsupported protocol version", "{\"expected\":1}", true);
      }

      if (request.kind != "request") {
        return error_response(request, "protocol_error", "message kind must be request", json_detail("kind", request.kind), true);
      }

      const std::string& op = request.op;

      if (op == "hello") {
        return handle_hello(request);
      }

      if (op == "eval") {
        return handle_eval(request);
      }

      if (op == "tick" || op == "cycle") {
        return handle_cycles(request);
      }

      if (op == "finish?") {
        return handle_finish(request);
      }

      if (op == "stop" || op == "shutdown") {
        return handle_stop(request);
      }

      if (op == "reset" || op == "poke" || op == "peek") {
        return error_response(
            request,
            "unsupported_feature",
            "operation requires generated signal accessors",
            json_detail("operation", op),
            false);
      }

      return error_response(
          request,
          "unsupported_command",
          "unsupported command",
          json_detail("operation", op),
          false);
    }

  private:
    DispatchResult handle_hello(const Request& request) {
      std::ostringstream body;
      body << "{\"wrapper\":\"sv_port_sim\",\"top_module\":" << json_quote(kTopModule)
           << ",\"protocol\":1,\"time\":" << session_.time() << "}";
      return respond(request, body.str());
    }

    DispatchResult handle_eval(const Request& request) {
      session_.eval();
      std::ostringstream body;
      body << "{\"time\":" << session_.time() << "}";
      return respond(request, body.str());
    }

    DispatchResult handle_cycles(const Request& request) {
      std::uint64_t cycles = 1;
      DispatchResult validation_error;

      if (!parse_cycles(request, cycles, validation_error)) {
        return validation_error;
      }

      session_.advance_cycles(cycles);

      std::ostringstream body;
      body << "{\"cycles\":" << cycles << ",\"time\":" << session_.time() << "}";
      return respond(request, body.str());
    }

    DispatchResult handle_finish(const Request& request) {
      std::ostringstream body;
      body << "{\"finished\":" << (session_.finished() ? "true" : "false")
           << ",\"time\":" << session_.time() << "}";
      return respond(request, body.str());
    }

    DispatchResult handle_stop(const Request& request) {
      std::ostringstream body;
      body << "{\"status\":\"stopped\",\"time\":" << session_.time() << "}";
      DispatchResult result = respond(request, body.str());
      result.stop = true;
      result.exit_code = 0;
      return result;
    }

    bool parse_cycles(const Request& request, std::uint64_t& cycles, DispatchResult& result) {
      bool found = false;
      std::string parse_error;

      if (!find_uint_field(request.body_json, "cycles", cycles, found, parse_error)) {
        result = error_response(
            request,
            "invalid_value",
            "invalid cycle count",
            json_detail("reason", parse_error),
            false);
        return false;
      }

      if (!found) {
        cycles = 1;
      }

      if (cycles == 0) {
        result = error_response(
            request,
            "invalid_value",
            "cycle count must be positive",
            "{\"cycles\":0}",
            false);
        return false;
      }

      return true;
    }

    SimulationSession& session_;
  };

  }  // namespace

  int main(int argc, char** argv) {
    set_binary_stdio();

    SimulationSession session(argc, argv);
    CommandDispatcher dispatcher(session);

    while (true) {
      const FrameRead frame = read_frame();

      if (frame.status == FrameRead::eof) {
        return finish_session(session, 0);
      }

      if (frame.status == FrameRead::fatal) {
        const Request request;
        write_frame(protocol_error_payload(request, frame.message));
        return finish_session(session, 1);
      }

      Request request;
      std::string parse_error;

      if (!parse_request(frame.payload, request, parse_error)) {
        write_frame(protocol_error_payload(request, parse_error));
        return finish_session(session, 1);
      }

      DispatchResult result;

      try {
        result = dispatcher.dispatch(request);
      } catch (const std::exception& exception) {
        result = error_response(
            request,
            "wrapper_fault",
            "wrapper fault",
            json_detail("reason", exception.what()),
            true);
      } catch (...) {
        result = error_response(
            request,
            "wrapper_fault",
            "wrapper fault",
            json_detail("reason", "unknown exception"),
            true);
      }

      if (!write_frame(result.payload)) {
        return finish_session(session, 1);
      }

      if (result.stop) {
        return finish_session(session, result.exit_code);
      }
    }
  }
  """

  @type top_module :: String.t()

  @doc """
  Returns the default C++ wrapper filename for `top_module`.

  The filename is formed by appending `_wrapper.cpp` to the validated
  top-module name.

  Returns `{:ok, filename}` on success.

  Returns `{:error, {:invalid_top_module, top_module}}` when `top_module` is
  not a binary or does not satisfy the accepted identifier format.

  ## Examples

      iex> SvPortSim.Verilator.Wrapper.filename("Counter")
      {:ok, "Counter_wrapper.cpp"}
      iex> SvPortSim.Verilator.Wrapper.filename("../Counter")
      {:error, {:invalid_top_module, "../Counter"}}

  """
  @spec filename(term()) :: {:ok, String.t()} | {:error, term()}
  def filename(top_module) when is_binary(top_module) do
    with :ok <- validate_top_module(top_module) do
      {:ok, "#{top_module}_wrapper.cpp"}
    end
  end

  def filename(top_module) do
    {:error, {:invalid_top_module, top_module}}
  end

  @doc """
  Generates the interactive C++ wrapper source for `top_module`.

  The generated source includes the Verilator-generated header
  `"V<top_module>.h"` and `verilated.h`. Its `main` function creates one
  `VerilatedContext`, one `V<top_module>` instance, and one command dispatcher
  before entering the request loop. `eval`, `tick`, and `cycle` use the same
  session state, and terminal paths finalize the model through one guarded
  cleanup helper.

  Returns `{:ok, source}` on success.

  Returns `{:error, {:invalid_top_module, top_module}}` when `top_module` is
  not a binary or does not satisfy the accepted identifier format.

  ## Examples

      iex> {:ok, source} = SvPortSim.Verilator.Wrapper.source("Counter")
      iex> source =~ ~s(#include "VCounter.h")
      true
      iex> source =~ "while (true)"
      true
      iex> source =~ ~s(op == "tick" || op == "cycle")
      true

  """
  @spec source(term()) :: {:ok, String.t()} | {:error, term()}
  def source(top_module) when is_binary(top_module) do
    with :ok <- validate_top_module(top_module) do
      {:ok, wrapper_source(top_module)}
    end
  end

  def source(top_module) do
    {:error, {:invalid_top_module, top_module}}
  end

  @doc """
  Explicit alias for `source/1` that documents interactive wrapper generation.

  ## Examples

      iex> {:ok, source} = SvPortSim.Verilator.Wrapper.interactive_source("Counter")
      iex> source =~ "SimulationSession"
      true

  """
  @spec interactive_source(term()) :: {:ok, String.t()} | {:error, term()}
  def interactive_source(top_module), do: source(top_module)

  @doc """
  Writes the generated interactive C++ wrapper source for `top_module` into `dir`.

  The output file is named with `filename/1` and placed directly under `dir`.
  The directory is created if it does not already exist. If the destination file
  already exists, it is overwritten.

  Returns `{:ok, path}` on success.

  Returns one of the following error tuples:

  * `{:error, {:invalid_arguments, top_module, dir}}` when either argument is
    not a binary
  * `{:error, {:invalid_top_module, top_module}}` when `top_module` is a
    binary but does not satisfy the accepted identifier format
  * `{:error, {:mkdir_failed, dir, reason}}` when creating `dir` fails
  * `{:error, {:write_failed, path, reason}}` when writing the wrapper source
    fails

  ## Example

      dir = Path.join(System.tmp_dir!(), "sv_port_sim_wrappers")
      {:ok, path} = SvPortSim.Verilator.Wrapper.write("Counter", dir)

  """
  @spec write(term(), term()) :: {:ok, Path.t()} | {:error, term()}
  def write(top_module, dir) when is_binary(top_module) and is_binary(dir) do
    with {:ok, filename} <- filename(top_module),
         {:ok, source} <- source(top_module),
         :ok <- mkdir_p(dir) do
      path = Path.join(dir, filename)

      case File.write(path, source) do
        :ok -> {:ok, path}
        {:error, reason} -> {:error, {:write_failed, path, reason}}
      end
    end
  end

  def write(top_module, dir) do
    {:error, {:invalid_arguments, top_module, dir}}
  end

  defp mkdir_p(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, dir, reason}}
    end
  end

  defp wrapper_source(top_module) do
    verilated_class = "V#{top_module}"

    @wrapper_template
    |> String.replace("@@VERILATED_CLASS@@", verilated_class)
    |> String.replace("@@TOP_MODULE@@", top_module)
  end

  defp validate_top_module(top_module) do
    if Regex.match?(@sv_identifier, top_module) do
      :ok
    else
      {:error, {:invalid_top_module, top_module}}
    end
  end
end
