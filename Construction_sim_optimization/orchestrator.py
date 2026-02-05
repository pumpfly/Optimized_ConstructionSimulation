from flask import Flask, request
# from PIL import Image


if __name__ == "__main__":
    server = Flask(__name__)

    tasks = {1: "alskdjf",
            2: "slakjf;sldjf", 
            3: "als;kdjl;sjf"}

    answers = {}

    @server.route("/")
    def index_handler():
        return "bobr"

    # Input
    @server.route("/input")
    def task_handler():
        if len(tasks) == 0:
            return "finished"
        id = list(tasks.keys())[0]
        task = tasks[id]
        del tasks[id]
        return f"{id}.) {task}"

    # The Orchestrator recieves answers (Output)
    @server.route(f"/handover")
    def handover_handler():
        id = request.args.get("id")
        answer = request.args.get("answer")
        answers[id] = answer
        return "done"


    @server.route("/answers")
    def answer_handler():
        return f"we have {len(answers)} answers:\n{answers}"

    server.run(port=7999)





