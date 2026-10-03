// Port of MessageFramerTests.swift.
#include "test_support.hpp"
#include "lint/message_framer.hpp"

using nib::MessageFramer;
using S = std::vector<std::string>;

TEST_CASE("MessageFramer: complete and multiple messages") {
    MessageFramer framer;
    CHECK(framer.push(MessageFramer::encode(R"({"id":1})")) == S{R"({"id":1})"});
    CHECK(framer.push(MessageFramer::encode(R"({"a":1})") + MessageFramer::encode(R"({"b":2})"))
          == S{R"({"a":1})", R"({"b":2})"});
}

TEST_CASE("MessageFramer: split across chunks") {
    MessageFramer framer;
    const std::string full = MessageFramer::encode(R"({"hello":"world"})");
    const size_t cut = full.size() - 5;
    CHECK(framer.push(full.substr(0, cut)).empty());
    CHECK(framer.push(full.substr(cut)) == S{R"({"hello":"world"})"});

    MessageFramer header;
    const std::string again = MessageFramer::encode(R"({"x":1})");
    CHECK(header.push(again.substr(0, 8)).empty());
    CHECK(header.push(again.substr(8)).size() == 1);
}

TEST_CASE("MessageFramer: byte at a time") {
    MessageFramer framer;
    S received;
    for (char c : MessageFramer::encode(R"({"drip":true})")) {
        for (auto& m : framer.push(std::string(1, c))) received.push_back(m);
    }
    CHECK(received == S{R"({"drip":true})"});
}

TEST_CASE("MessageFramer: body length is bytes, not characters") {
    MessageFramer framer;
    const std::string json = "{\"text\":\"caf\xC3\xA9 \xF0\x9F\x98\x80\"}";
    CHECK(framer.push(MessageFramer::encode(json)) == S{json});
}

TEST_CASE("MessageFramer: trailing partial message is held") {
    MessageFramer framer;
    const std::string first = MessageFramer::encode(R"({"first":1})");
    const std::string second = MessageFramer::encode(R"({"second":2})");
    CHECK(framer.push(first + second.substr(0, 10)) == S{R"({"first":1})"});
    CHECK(framer.push(second.substr(10)) == S{R"({"second":2})"});
}

TEST_CASE("MessageFramer: a bad header does not wedge the stream") {
    MessageFramer framer;
    const auto out = framer.push("Bogus: x\r\n\r\n" + MessageFramer::encode(R"({"ok":1})"));
    CHECK(out == S{R"({"ok":1})"});
}

TEST_CASE("MessageFramer: encode uses the byte count") {
    CHECK(MessageFramer::encode("{}").rfind("Content-Length: 2\r\n\r\n", 0) == 0);
}
