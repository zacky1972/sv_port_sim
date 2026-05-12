defmodule SvPortSim.Verilator.Wrapper.Template do
  @moduledoc """
  Renders the interactive C++ wrapper template for Verilated top modules.

  This module owns placeholder substitution for the generated C++ runtime
  skeleton. Accessor-specific fragments are expected to be supplied by
  `SvPortSim.Verilator.Wrapper.Accessor.context/1`.
  """

  @type context :: %{
          required(:signal_specs_json) => String.t(),
          required(:poke_cases) => String.t(),
          required(:peek_cases) => String.t(),
          optional(atom()) => term()
        }

  @wrapper_template ~S"""
  #include "@@VERILATED_CLASS@@.h"
  #include "verilated.h"

  #include <cctype>
  #include <cstddef>
  #include <cstdint>
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
  const char* kSignalSpecsJson = R"svps_json(@@SIGNAL_SPECS_JSON@@)svps_json";

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

  struct EncodedValue {
    std::string bits;
    int width = 0;
  };

  struct AccessorResult {
    bool ok = false;
    EncodedValue value;
    std::string code;
    std::string message;
    std::string signal;
  };

  AccessorResult ok_accessor(const EncodedValue& value) {
    AccessorResult result;
    result.ok = true;
    result.value = value;
    return result;
  }

  AccessorResult invalid_signal_accessor(const std::string& signal,
                                         const std::string& message) {
    AccessorResult result;
    result.ok = false;
    result.code = "invalid_signal";
    result.message = message;
    result.signal = signal;
    return result;
  }

  AccessorResult invalid_value_accessor(const std::string& signal,
                                        const std::string& message) {
    AccessorResult result;
    result.ok = false;
    result.code = "invalid_value";
    result.message = message;
    result.signal = signal;
    return result;
  }

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

  std::string signal_detail(const std::string& signal) {
    if (signal.empty()) {
      return "{}";
    }

    return json_detail("signal", signal);
  }

  std::string encoded_value_json(const EncodedValue& value) {
    std::ostringstream out;
    out << "{\"bits\":" << json_quote(value.bits)
        << ",\"width\":" << value.width << "}";
    return out.str();
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

  bool find_uint_field(const std::string& object_json,
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

  bool parse_encoded_value(JsonCursor& json, EncodedValue& value, std::string& error) {
    bool seen_bits = false;
    bool seen_width = false;

    if (!json.consume('{')) {
      error = "encoded value must be an object";
      return false;
    }

    if (json.consume('}')) {
      error = "encoded value must contain bits and width";
      return false;
    }

    while (true) {
      std::string field;

      if (!json.parse_string(field) || !json.consume(':')) {
        error = "invalid encoded value field";
        return false;
      }

      if (field == "bits") {
        if (seen_bits || !json.parse_string(value.bits)) {
          error = "invalid encoded bits";
          return false;
        }

        seen_bits = true;
      } else if (field == "width") {
        std::uint64_t parsed_width = 0;

        if (seen_width || !json.parse_uint64(parsed_width) || parsed_width == 0 ||
            parsed_width > static_cast<std::uint64_t>(std::numeric_limits<int>::max())) {
          error = "invalid encoded width";
          return false;
        }

        value.width = static_cast<int>(parsed_width);
        seen_width = true;
      } else {
        error = "unknown encoded value field: " + field;
        return false;
      }

      if (json.consume('}')) {
        break;
      }

      if (!json.consume(',')) {
        error = "expected encoded value separator";
        return false;
      }
    }

    if (!seen_bits || !seen_width) {
      error = "encoded value must contain bits and width";
      return false;
    }

    return true;
  }

  bool parse_poke_body(const std::string& body_json,
                       std::string& signal,
                       EncodedValue& value,
                       std::string& code,
                       std::string& message) {
    JsonCursor json(body_json);
    bool seen_signal = false;
    bool seen_value = false;

    if (!json.consume('{')) {
      code = "invalid_value";
      message = "body must be a JSON object";
      return false;
    }

    if (json.consume('}')) {
      code = "invalid_signal";
      message = "missing signal";
      return false;
    }

    while (true) {
      std::string field;

      if (!json.parse_string(field) || !json.consume(':')) {
        code = "invalid_value";
        message = "invalid poke body";
        return false;
      }

      if (field == "signal") {
        if (seen_signal || !json.parse_string(signal) || signal.empty()) {
          code = "invalid_signal";
          message = "invalid signal";
          return false;
        }

        seen_signal = true;
      } else if (field == "value") {
        if (seen_value || !parse_encoded_value(json, value, message)) {
          code = "invalid_value";
          if (message.empty()) {
            message = "invalid encoded value";
          }
          return false;
        }

        seen_value = true;
      } else {
        code = "invalid_value";
        message = "unknown poke body field: " + field;
        return false;
      }

      if (json.consume('}')) {
        break;
      }

      if (!json.consume(',')) {
        code = "invalid_value";
        message = "expected poke body separator";
        return false;
      }
    }

    if (!json.at_end()) {
      code = "invalid_value";
      message = "trailing data after poke body";
      return false;
    }

    if (!seen_signal) {
      code = "invalid_signal";
      message = "missing signal";
      return false;
    }

    if (!seen_value) {
      code = "invalid_value";
      message = "missing encoded value";
      return false;
    }

    return true;
  }

  bool parse_peek_body(const std::string& body_json,
                       std::string& signal,
                       std::string& code,
                       std::string& message) {
    JsonCursor json(body_json);
    bool seen_signal = false;

    if (!json.consume('{')) {
      code = "invalid_signal";
      message = "body must be a JSON object";
      return false;
    }

    if (json.consume('}')) {
      code = "invalid_signal";
      message = "missing signal";
      return false;
    }

    while (true) {
      std::string field;

      if (!json.parse_string(field) || !json.consume(':')) {
        code = "invalid_signal";
        message = "invalid peek body";
        return false;
      }

      if (field == "signal") {
        if (seen_signal || !json.parse_string(signal) || signal.empty()) {
          code = "invalid_signal";
          message = "invalid signal";
          return false;
        }

        seen_signal = true;
      } else {
        code = "invalid_value";
        message = "unknown peek body field: " + field;
        return false;
      }

      if (json.consume('}')) {
        break;
      }

      if (!json.consume(',')) {
        code = "invalid_value";
        message = "expected peek body separator";
        return false;
      }
    }

    if (!json.at_end()) {
      code = "invalid_value";
      message = "trailing data after peek body";
      return false;
    }

    if (!seen_signal) {
      code = "invalid_signal";
      message = "missing signal";
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

        if (seen_version || !json.parse_uint64(parsed_version) ||
            parsed_version > std::numeric_limits<std::uint32_t>::max()) {
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

  std::string response_envelope(std::uint64_t id,
                                const std::string& op,
                                const std::string& body_json) {
    std::ostringstream out;
    out << "{\"v\":" << kProtocolVersion
        << ",\"id\":" << id
        << ",\"kind\":\"response\""
        << ",\"op\":" << json_quote(op)
        << ",\"body\":" << body_json << "}";
    return out.str();
  }

  std::string error_envelope(std::uint64_t id,
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
        << ",\"fatal\":" << (fatal ? "true" : "false") << "}}";
    return out.str();
  }

  std::string protocol_error_payload(const Request& request, const std::string& message) {
    return error_envelope(request.has_id ? request.id : 0,
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

  DispatchResult error_response(const Request& request,
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

  bool valid_two_state_encoded_value(const EncodedValue& value, int expected_width) {
    if (expected_width <= 0 || value.width != expected_width ||
        static_cast<int>(value.bits.size()) != expected_width) {
      return false;
    }

    for (std::string::const_iterator it = value.bits.begin(); it != value.bits.end(); ++it) {
      if (*it != '0' && *it != '1') {
        return false;
      }
    }

    return true;
  }

  std::uint64_t bits_to_uint64(const std::string& bits) {
    std::uint64_t value = 0;

    for (std::string::const_iterator it = bits.begin(); it != bits.end(); ++it) {
      value = (value << 1) | (*it == '1' ? 1ULL : 0ULL);
    }

    return value;
  }

  std::string uint64_to_bits(std::uint64_t value, int width) {
    std::string bits(static_cast<std::size_t>(width), '0');

    for (int index = width - 1; index >= 0; --index) {
      bits[static_cast<std::size_t>(width - 1 - index)] =
          ((value >> index) & 1ULL) ? '1' : '0';
    }

    return bits;
  }

  EncodedValue encode_signal(std::uint64_t value, int width) {
    EncodedValue encoded;
    encoded.bits = uint64_to_bits(value, width);
    encoded.width = width;
    return encoded;
  }

  class SimulationSession {
   public:
    SimulationSession(int argc, char** argv)
        : contextp_(new VerilatedContext),
          top_(nullptr),
          finalized_(false),
          cycle_(0) {
      contextp_->commandArgs(argc, argv);
      top_.reset(new @@VERILATED_CLASS@@{contextp_.get()});
    }

    ~SimulationSession() {
      final();
    }

    void eval() {
      top_->eval();
    }

    void advance_cycles(std::uint64_t cycles) {
      for (std::uint64_t cycle = 0; cycle < cycles; ++cycle) {
        contextp_->timeInc(1);
        top_->eval();
        ++cycle_;
      }
    }

    void final() {
      if (!finalized_) {
        top_->final();
        finalized_ = true;
      }
    }

    bool finished() const {
      return contextp_->gotFinish();
    }

    std::uint64_t time() const {
      return static_cast<std::uint64_t>(contextp_->time());
    }

    std::uint64_t cycle() const {
      return cycle_;
    }

    @@VERILATED_CLASS@@* top_model() {
      return top_.get();
    }

   private:
    std::unique_ptr<VerilatedContext> contextp_;
    std::unique_ptr<@@VERILATED_CLASS@@> top_;
    bool finalized_;
    std::uint64_t cycle_;
  };

  AccessorResult poke_signal(SimulationSession& session,
                             const std::string& signal,
                             const EncodedValue& value) {
  @@POKE_CASES@@
    return invalid_signal_accessor(signal, "unknown signal");
  }

  AccessorResult peek_signal(SimulationSession& session, const std::string& signal) {
  @@PEEK_CASES@@
    return invalid_signal_accessor(signal, "unknown signal");
  }

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

      if (op == "metadata") {
        return handle_metadata(request);
      }

      if (op == "hello") {
        return handle_hello(request);
      }

      if (op == "eval") {
        return handle_eval(request);
      }

      if (op == "tick" || op == "cycle") {
        return handle_cycles(request);
      }

      if (op == "poke") {
        return handle_poke(request);
      }

      if (op == "peek") {
        return handle_peek(request);
      }

      if (op == "finish?") {
        return handle_finish(request);
      }

      if (op == "stop" || op == "shutdown") {
        return handle_stop(request);
      }

      if (op == "reset") {
        return error_response(request,
                              "unsupported_feature",
                              "operation requires generated reset sequencing",
                              json_detail("operation", op),
                              false);
      }

      return error_response(request,
                            "unsupported_command",
                            "unsupported command",
                            json_detail("operation", op),
                            false);
    }

   private:
    DispatchResult handle_metadata(const Request& request) {
      std::ostringstream body;
      body << "{\"top\":" << json_quote(kTopModule)
           << ",\"signals\":" << kSignalSpecsJson
           << ",\"cycle\":" << session_.cycle()
           << ",\"protocol\":{\"version\":" << kProtocolVersion << "}}";
      return respond(request, body.str());
    }

    DispatchResult handle_hello(const Request& request) {
      std::ostringstream body;
      body << "{\"wrapper\":\"sv_port_sim\",\"top_module\":" << json_quote(kTopModule)
           << ",\"protocol\":" << kProtocolVersion
           << ",\"time\":" << session_.time()
           << ",\"cycle\":" << session_.cycle() << "}";
      return respond(request, body.str());
    }

    DispatchResult handle_eval(const Request& request) {
      session_.eval();

      std::ostringstream body;
      body << "{\"time\":" << session_.time() << ",\"cycle\":" << session_.cycle() << "}";
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
      body << "{\"cycles\":" << cycles
           << ",\"time\":" << session_.time()
           << ",\"cycle\":" << session_.cycle() << "}";
      return respond(request, body.str());
    }

    DispatchResult handle_poke(const Request& request) {
      std::string signal;
      EncodedValue value;
      std::string code;
      std::string message;

      if (!parse_poke_body(request.body_json, signal, value, code, message)) {
        return error_response(request, code, message, signal_detail(signal), false);
      }

      const AccessorResult result = poke_signal(session_, signal, value);

      if (!result.ok) {
        return error_response(request, result.code, result.message, signal_detail(result.signal), false);
      }

      std::ostringstream body;
      body << "{\"signal\":" << json_quote(signal)
           << ",\"value\":" << encoded_value_json(result.value)
           << ",\"cycle\":" << session_.cycle() << "}";
      return respond(request, body.str());
    }

    DispatchResult handle_peek(const Request& request) {
      std::string signal;
      std::string code;
      std::string message;

      if (!parse_peek_body(request.body_json, signal, code, message)) {
        return error_response(request, code, message, signal_detail(signal), false);
      }

      const AccessorResult result = peek_signal(session_, signal);

      if (!result.ok) {
        return error_response(request, result.code, result.message, signal_detail(result.signal), false);
      }

      std::ostringstream body;
      body << "{\"signal\":" << json_quote(signal)
           << ",\"value\":" << encoded_value_json(result.value)
           << ",\"cycle\":" << session_.cycle() << "}";
      return respond(request, body.str());
    }

    DispatchResult handle_finish(const Request& request) {
      std::ostringstream body;
      body << "{\"finished\":" << (session_.finished() ? "true" : "false")
           << ",\"time\":" << session_.time()
           << ",\"cycle\":" << session_.cycle() << "}";
      return respond(request, body.str());
    }

    DispatchResult handle_stop(const Request& request) {
      const char* status = request.op == "shutdown" ? "closing" : "stopped";

      std::ostringstream body;
      body << "{\"status\":\"" << status << "\",\"time\":" << session_.time()
           << ",\"cycle\":" << session_.cycle() << "}";

      DispatchResult result = respond(request, body.str());
      result.stop = true;
      result.exit_code = 0;
      return result;
    }

    bool parse_cycles(const Request& request, std::uint64_t& cycles, DispatchResult& result) {
      bool found = false;
      std::string parse_error;

      if (!find_uint_field(request.body_json, "cycles", cycles, found, parse_error)) {
        result = error_response(request,
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
        result = error_response(request,
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
        result = error_response(request,
                                "wrapper_fault",
                                "wrapper fault",
                                json_detail("reason", exception.what()),
                                true);
      } catch (...) {
        result = error_response(request,
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

  @doc """
    Renders wrapper C++ source for `top_module` using prebuilt accessor context.
  """
  @spec render(String.t(), context()) :: String.t()
  def render(top_module, %{
        signal_specs_json: signal_specs_json,
        poke_cases: poke_cases,
        peek_cases: peek_cases
      })
      when is_binary(top_module) and is_binary(signal_specs_json) and is_binary(poke_cases) and
             is_binary(peek_cases) do
    verilated_class = "V#{top_module}"

    @wrapper_template
    |> String.replace("@@VERILATED_CLASS@@", verilated_class)
    |> String.replace("@@TOP_MODULE@@", cpp_string(top_module))
    |> String.replace("@@SIGNAL_SPECS_JSON@@", signal_specs_json)
    |> String.replace("@@POKE_CASES@@", poke_cases)
    |> String.replace("@@PEEK_CASES@@", peek_cases)
  end

  defp cpp_string(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end
end