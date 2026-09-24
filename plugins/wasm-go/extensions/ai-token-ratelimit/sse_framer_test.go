// Copyright (c) 2026 TokenVolt
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package main

import (
	"fmt"
	"strings"
	"testing"

	"github.com/higress-group/proxy-wasm-go-sdk/proxywasm/types"
	"github.com/higress-group/wasm-go/pkg/test"
	"github.com/higress-group/wasm-go/pkg/wrapper"
	"github.com/stretchr/testify/require"
)

var tokenRateLimitSSEUsageEvent = []byte(`data: {"id":"chatcmpl-tokenvolt","object":"chat.completion.chunk","choices":[],"usage":{"prompt_tokens":100000,"completion_tokens":214159,"total_tokens":314159}}` + "\n\n")

func TestSSEFramerReassemblesUsageAtEveryByteBoundary(t *testing.T) {
	for offset := 1; offset < len(tokenRateLimitSSEUsageEvent); offset++ {
		f := &sseFramer{}
		require.Emptyf(t, f.frameCallback(tokenRateLimitSSEUsageEvent[:offset]), "offset %d", offset)
		require.Equalf(t,
			[][]byte{wrapper.UnifySSEChunk(tokenRateLimitSSEUsageEvent)},
			f.frameCallback(tokenRateLimitSSEUsageEvent[offset:]),
			"offset %d", offset,
		)
	}
}

func TestSSEFramerHandlesMultipleEventsAndFinalUnterminatedEvent(t *testing.T) {
	f := &sseFramer{}
	first := []byte("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n")
	last := []byte("data: {\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3,\"total_tokens\":5}}")

	events := f.frameCallback(append(append([]byte(nil), first...), last...))
	require.Equal(t, [][]byte{first}, events)
	drained, overflowCount := f.drain()
	require.Equal(t, last, drained)
	require.Zero(t, overflowCount)
}

func TestSSEFramerResynchronizesAfterOversizedIncompleteEvent(t *testing.T) {
	f := &sseFramer{}
	require.Empty(t, f.frameCallback([]byte(strings.Repeat("x", maxIncompleteSSEEventBytes+1))))
	require.True(t, f.resyncing)

	valid := []byte("discarded\n\ndata: {\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3,\"total_tokens\":5}}\n\n")
	require.Equal(t,
		[][]byte{[]byte("data: {\"usage\":{\"prompt_tokens\":2,\"completion_tokens\":3,\"total_tokens\":5}}\n\n")},
		f.frameCallback(valid),
	)
	_, overflowCount := f.drain()
	require.Equal(t, 1, overflowCount)
}

func TestStreamingUsageSplitAcrossCallbacksIncrementsRedis(t *testing.T) {
	test.RunTest(t, func(t *testing.T) {
		for offset := 1; offset < len(tokenRateLimitSSEUsageEvent); offset++ {
			host, status := test.NewTestHost(globalThresholdConfig)
			require.Equalf(t, types.OnPluginStartStatusOK, status, "offset %d", offset)

			action := host.CallOnHttpRequestHeaders([][2]string{
				{":authority", "api.tokenvolt.net"},
				{":path", "/v1/chat/completions"},
				{":method", "POST"},
			})
			require.Equalf(t, types.HeaderStopAllIterationAndWatermark, action, "offset %d", offset)
			host.CallOnRedisCall(0, multiRuleResp([3]int{1000, 1, 60}))

			require.Equal(t, types.ActionContinue, host.CallOnHttpResponseHeaders([][2]string{
				{":status", "200"},
				{"content-type", "text/event-stream; charset=utf-8"},
			}))
			require.Equal(t, types.ActionContinue, host.CallOnHttpStreamingResponseBody(tokenRateLimitSSEUsageEvent[:offset], false))
			require.Emptyf(t, host.GetRedisCalloutAttributes(), "partial event must not increment at offset %d", offset)
			require.Equal(t, types.ActionContinue, host.CallOnHttpStreamingResponseBody(tokenRateLimitSSEUsageEvent[offset:], true))

			calls := host.GetRedisCalloutAttributes()
			require.Lenf(t, calls, 1, "complete usage event must increment at offset %d", offset)
			require.Containsf(t, string(calls[0].Query), "\r\n314159\r\n", "wrong token increment at offset %d: %q", offset, calls[0].Query)

			host.CompleteHttp()
			host.Reset()
		}
	})
}

func TestStreamingUsageWithoutFinalDelimiterIncrementsAtEOS(t *testing.T) {
	test.RunTest(t, func(t *testing.T) {
		host, status := test.NewTestHost(globalThresholdConfig)
		defer host.Reset()
		require.Equal(t, types.OnPluginStartStatusOK, status)

		require.Equal(t, types.HeaderStopAllIterationAndWatermark, host.CallOnHttpRequestHeaders([][2]string{
			{":authority", "api.tokenvolt.net"},
			{":path", "/v1/chat/completions"},
			{":method", "POST"},
		}))
		host.CallOnRedisCall(0, multiRuleResp([3]int{1000, 1, 60}))
		require.Equal(t, types.ActionContinue, host.CallOnHttpResponseHeaders([][2]string{
			{":status", "200"},
			{"content-type", "text/event-stream"},
		}))

		unterminated := tokenRateLimitSSEUsageEvent[:len(tokenRateLimitSSEUsageEvent)-2]
		offset := len(unterminated) / 2
		require.Equal(t, types.ActionContinue, host.CallOnHttpStreamingResponseBody(unterminated[:offset], false))
		require.Equal(t, types.ActionContinue, host.CallOnHttpStreamingResponseBody(unterminated[offset:], true))

		calls := host.GetRedisCalloutAttributes()
		require.Len(t, calls, 1)
		require.Contains(t, string(calls[0].Query), "\r\n314159\r\n", fmt.Sprintf("unexpected Redis query: %q", calls[0].Query))
		host.CompleteHttp()
	})
}
