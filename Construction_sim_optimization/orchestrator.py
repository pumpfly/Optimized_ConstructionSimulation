from flask import Flask, request
import random
import json
# from PIL import Image


if __name__ == "__main__":
    server = Flask(__name__)

    # 1,5 months = 3942000 seconds
    # 2 hours = 7200 seconds
    # 3 hours = 10800

    def generate_schedule() -> dict:
        bagger_count = random.randrange(1, 15)
        dirt_truck_count = random.randrange(1, 15)
        material_truck_count = random.randrange(1, 4) # four because for now four pipes will be installed

        schedule = {}

        # bagger schedule
        for i in range(bagger_count):
            key = str(random.randrange(1, 9000))
            if key not in schedule:
                schedule[key] = []
            schedule[key].append("Bagger")

        # dirt truck schedule
        for i in range(dirt_truck_count):
            key = str(random.randrange(1, 9000))
            if key not in schedule:
                schedule[key] = []
            schedule[key].append("DirtTruck")

        # material truck schedule
        for i in range(material_truck_count):
            key = str(random.randrange(1, 9000))
            if key not in schedule:
                schedule[key] = []
            schedule[key].append("MaterialTruck")

        # crane schedule - there will only be one crane
        key = str(random.randrange(1, 9000))
        if key not in schedule:
            schedule[key] = []
        schedule[key].append("Crane")

        return schedule

    # One task in the queue for now; extend this list to queue more tasks
    task_queue = [
        {"id": 0, "schedule": generate_schedule()}
    ]

    answers = {}

    @server.route("/")
    def index_handler():
        return "bobr"

    # Input: worker polls this endpoint to receive the next task
    @server.route("/input")
    def task_handler():
        return json.dumps({
            "id": 0, "schedule": {"1": ["Bagger"],
                                  "60": ["DirtTruck"],
                                  "120": ["Bagger"],
                                  "180": ["DirtTruck"],
                                  "240": ["Bagger"],
                                  "300": ["DirtTruck"],
                                  "360": ["Bagger"],
                                  "420": ["DirtTruck"],
                                  "480": ["Bagger"],
                                  "540": ["DirtTruck"],
                                  "2": ["Bagger"],
                                  "61": ["DirtTruck"],
                                  "121": ["Bagger"],
                                  "181": ["DirtTruck"],
                                  "241": ["Bagger"],
                                  "301": ["DirtTruck"],
                                  "361": ["Bagger"],
                                  "421": ["DirtTruck"],
                                  "481": ["Bagger"],
                                  "541": ["DirtTruck"],
                                  "3600": ["Crane"],
                                  "4000": ["MaterialTruck"],
                                  "4001": ["MaterialTruck"]
                                  }})

        #if len(task_queue) == 0:
        #    return "finished"

        #task = task_queue.pop(0)
        #return json.dumps({"id": task["id"], "schedule": task["schedule"]})

    # The Orchestrator receives answers (Output)
    @server.route("/handover")
    def handover_handler():
        id = request.args.get("id")
        answer = request.args.get("answer")
        answers[id] = answer
        return "done"

    @server.route("/answers")
    def answer_handler():
        return f"we have {len(answers)} answers:\n{answers}"

    server.run(port=7999)
