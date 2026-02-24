from flask import Flask, request
import random
# from PIL import Image


if __name__ == "__main__":
    server = Flask(__name__)

    # 1,5 months = 3942000 seconds
    # 2 hours = 7200 seconds

    baggerCount = random.randrange(1, 15)
    dirtTruckCount = random.randrange(1, 15)
    materialTruckCount = random.randrange(1, 4) # four because for now four pipes will be installed and each truck can carry at least one and at max two
    # A material truck with two pipes is slower than trucks with just one

    # The dictionary of all agents and their schedule
    mainSchedule = {}

    # bagger schedule
    for i in range(baggerCount):
        key = random.randrange(1, 7200)
        if key not in mainSchedule:
            mainSchedule[key] = []
        mainSchedule[key].append("Bagger") # 2 hours max for debuging purposes
    
    # dirt truck schedule
    for i in range(dirtTruckCount):
        key = random.randrange(1, 7200)
        if key not in mainSchedule:
            mainSchedule[key] = []
        mainSchedule[key].append("DirtTruck")
    
    # material truck schedule
    for i in range(materialTruckCount):
        key = random.randrange(1, 7200)
        if key not in mainSchedule:
            mainSchedule[key] = []
        mainSchedule[key].append("MaterialTruck")

    # crane schedule - There will only be one crane
    key = random.randrange(1, 7200)
    if key not in mainSchedule:
        mainSchedule[key] = []
    mainSchedule[key].append("Crane")

    answers = {}

    @server.route("/")
    def index_handler():
        return "bobr"

    # Input
    @server.route("/input")
    def task_handler():
        if len(mainSchedule) == 0:
            return "finished"
        
        agentKey = list(mainSchedule.keys())[0]
        input = mainSchedule[agentKey]

        del mainSchedule[agentKey]

        return f"{agentKey} - {input}"


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





