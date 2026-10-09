package provider

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestMessagesCacheUsagePresence(t *testing.T) {
	for _, tc := range []struct {
		name, details string
		known         bool
		cached, input float64
	}{
		{"zero", `,"prompt_tokens_details":{"cached_tokens":0}`, true, 0, 15},
		{"hit", `,"prompt_tokens_details":{"cached_tokens":5}`, true, 5, 10},
		{"absent", "", false, 0, 15},
		{"empty_details", `,"prompt_tokens_details":{}`, false, 0, 15},
		{"null_cache", `,"prompt_tokens_details":{"cached_tokens":null}`, false, 0, 15},
		{"null_details", `,"prompt_tokens_details":null`, false, 0, 15},
	} {
		t.Run(tc.name, func(t *testing.T) {
			payload := fmt.Sprintf(`{"id":"usage-test","model":"test","choices":[],"usage":{"prompt_tokens":15,"completion_tokens":16,"total_tokens":31%s}}`, tc.details)
			for _, streaming := range []bool{false, true} {
				converter := &ClaudeToOpenAIConverter{}
				var result []byte
				var err error
				if streaming {
					result, err = converter.ConvertOpenAIStreamResponseToClaude(newMapCtx(), []byte("data: "+payload+"\n\n"), false)
				} else {
					result, err = converter.ConvertOpenAIResponseToClaude(nil, []byte(payload))
				}
				require.NoError(t, err)
				var usages []map[string]interface{}
				for _, line := range strings.Split(string(result), "\n") {
					line = strings.TrimPrefix(line, "data: ")
					if !strings.HasPrefix(line, "{") {
						continue
					}
					var event map[string]interface{}
					require.NoError(t, json.Unmarshal([]byte(line), &event))
					if streaming && event["type"] != "message_delta" {
						continue
					}
					if usage, ok := event["usage"].(map[string]interface{}); ok {
						usages = append(usages, usage)
					}
				}
				require.Len(t, usages, 1)
				cache, present := usages[0]["cache_read_input_tokens"]
				require.Equal(t, tc.known, present, "streaming=%v", streaming)
				if tc.known {
					require.Equal(t, tc.cached, cache)
				}
				require.Equal(t, tc.input, usages[0]["input_tokens"])
				require.Equal(t, float64(16), usages[0]["output_tokens"])
			}
		})
	}
}
