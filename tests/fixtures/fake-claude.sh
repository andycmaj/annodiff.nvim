#!/bin/sh
# fake `claude -p` for app/agent tests. records argv and stdin, then behaves per FAKE_CLAUDE_MODE.
printf '%s\n' "$@" > "$FAKE_CLAUDE_RECORD.args"
cat > "$FAKE_CLAUDE_RECORD.stdin"
pwd -P > "$FAKE_CLAUDE_RECORD.pwd"
case "$FAKE_CLAUDE_MODE" in
ok)
  echo '{"type":"system","subtype":"init","session_id":"sess-ok"}'
  echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hel"}},"parent_tool_use_id":null}'
  echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"lo"}},"parent_tool_use_id":null}'
  echo '{"type":"result","subtype":"success","is_error":false,"result":"hello","session_id":"sess-ok"}'
  ;;
stderr)
  echo 'Error: not logged in' >&2
  echo 'more detail' >&2
  exit 1
  ;;
silent)
  exit 3
  ;;
hang)
  echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"thinking"}},"parent_tool_use_id":null}'
  sleep 30 &
  echo $! > "$FAKE_CLAUDE_RECORD.child"
  wait
  ;;
stall)
  # one line, then silence until killed
  echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"thinking"}},"parent_tool_use_id":null}'
  sleep 30 &
  wait
  ;;
slow)
  # silent long enough to stall, then answers
  echo '{"type":"system","subtype":"init","session_id":"sess-slow"}'
  sleep "${FAKE_CLAUDE_PAUSE:-1}"
  echo '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"late"}},"parent_tool_use_id":null}'
  sleep 0.3
  echo '{"type":"result","subtype":"success","is_error":false,"result":"late","session_id":"sess-slow"}'
  ;;
esac
