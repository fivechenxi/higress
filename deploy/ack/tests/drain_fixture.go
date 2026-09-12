// Copyright 2026 Alibaba. Licensed under the Apache License, Version 2.0.
// Isolated drain test fixture: no real model calls or credentials.
package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "client" {
		stream := os.Args[3] == "stream"
		seconds := 20
		if len(os.Args) > 5 {
			seconds, _ = strconv.Atoi(os.Args[5])
		}
		body, _ := json.Marshal(map[string]any{"model": "drain-fixture", "stream": stream, "delay_seconds": seconds, "test_id": os.Args[4]})
		start := time.Now()
		req, _ := http.NewRequest("POST", os.Args[2]+"/v1/chat/completions", bytes.NewReader(body))
		req.Host = "drain.test"
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Request-Id", os.Args[4])
		c := &http.Client{Timeout: 90 * time.Second}
		r, e := c.Do(req)
		result := map[string]any{"id": os.Args[4], "complete": false, "mode": os.Args[3]}
		if e != nil {
			result["error"] = e.Error()
		} else {
			result["status"] = r.StatusCode
			if stream {
				s := bufio.NewScanner(r.Body)
				for s.Scan() {
					line := s.Text()
					if line == "data: [DONE]" {
						result["complete"] = true
					}
					if strings.HasPrefix(line, "data: {") {
						var v map[string]any
						if json.Unmarshal([]byte(strings.TrimPrefix(line, "data: ")), &v) == nil && v["usage"] != nil {
							result["usage"] = v["usage"]
							result["upstream_id"] = v["id"]
						}
					}
				}
				if s.Err() != nil {
					result["error"] = s.Err().Error()
				}
			} else {
				data, err := io.ReadAll(r.Body)
				var v map[string]any
				if err == nil && json.Unmarshal(data, &v) == nil {
					result["usage"] = v["usage"]
					result["upstream_id"] = v["id"]
					result["complete"] = r.StatusCode == 200 && v["usage"] != nil
				} else if err != nil {
					result["error"] = err.Error()
				}
			}
			r.Body.Close()
		}
		result["duration_s"] = time.Since(start).Seconds()
		json.NewEncoder(os.Stdout).Encode(result)
		if result["complete"] != true {
			os.Exit(2)
		}
		return
	}
	delay := 20
	if v, e := strconv.Atoi(os.Getenv("DELAY_SECONDS")); e == nil {
		delay = v
	}
	http.HandleFunc("/v1/chat/completions", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		requestDelay := delay
		if n, ok := body["delay_seconds"].(float64); ok && n >= 1 && n <= 60 {
			requestDelay = int(n)
		}
		id := r.Header.Get("X-Request-Id")
		fmt.Println("START", body["test_id"])
		usage := map[string]int{"prompt_tokens": 20, "completion_tokens": 20, "total_tokens": 40}
		w.Header().Set("X-Request-Id", id)
		if body["stream"] == true {
			w.Header().Set("Content-Type", "text/event-stream")
			f := w.(http.Flusher)
			for i := 0; i < requestDelay; i++ {
				select {
				case <-r.Context().Done():
					fmt.Println("CANCELED", id)
					return
				case <-time.After(time.Second):
				}
				fmt.Fprintf(w, "data: {\"id\":%q,\"model\":\"drain-fixture\",\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n", id)
				f.Flush()
			}
			data, _ := json.Marshal(map[string]any{"id": id, "model": "drain-fixture", "choices": []any{}, "usage": usage})
			fmt.Fprintf(w, "data: %s\n\ndata: [DONE]\n\n", data)
			f.Flush()
		} else {
			select {
			case <-r.Context().Done():
				fmt.Println("CANCELED", id)
				return
			case <-time.After(time.Duration(requestDelay) * time.Second):
			}
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]any{"id": id, "model": "drain-fixture", "choices": []any{}, "usage": usage})
		}
		fmt.Println("END", id)
	})
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) { fmt.Fprint(w, "ok") })
	if err := http.ListenAndServe(":8080", nil); err != nil {
		panic(err)
	}
}
