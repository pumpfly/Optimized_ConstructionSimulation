extends Node

var timer: float = 0
const INTERVAL: float = 1
	
func _process(delta: float) -> void:
	timer += delta 
	if timer > INTERVAL:
		timer = 0
		# Creates an HTTP request node and connects its completion signal.
		var http_request: HTTPRequest = HTTPRequest.new()
		add_child(http_request)
		http_request.request_completed.connect(self._http_request_completed)

		var error = http_request.request("http://127.0.0.1:7999/task")
		if error != OK:
			push_error("An error occurred in the HTTP request.")


# Called when the HTTP request is completed.
func _http_request_completed(result, response_code, headers, body):
	if result != HTTPRequest.RESULT_SUCCESS:
		push_error("something went wrong")
	
	var id = body[0]
	print(id)
	if body[0] == 102:
		print(body[0])
		return
	var answer = randi_range(0, 1000)
	
	var url_string = "http://127.0.0.1:7999/handover?answer=%s&id=%s"
	var actualUrl_string = url_string % [answer, id]
	var http_request_2 = HTTPRequest.new()
	add_child(http_request_2)
	var error = http_request_2.request(actualUrl_string)
	if error != OK:
		push_error("An error occurred in the HTTP request.")
		
	var answer_string = "gave answer %s for %s" % [answer, id]
	print(answer_string)
