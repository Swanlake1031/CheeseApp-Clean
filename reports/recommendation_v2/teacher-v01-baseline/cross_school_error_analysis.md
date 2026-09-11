# Cross-school error analysis

Synthetic performance is NOT production validation. Inspect provisional labels before attributing errors to the classifier.

## False positives

None.

## False negatives

- `cs_047` / campus_event: q=0.539378, y=1, confidence=0.67: "club fair到底能不能认识到人啊"
- `cs_048` / campus_event: q=0.522670, y=1, confidence=0.75: "开学活动一个人去正常吗"
- `cs_270` / health_wellness: q=0.543612, y=1, confidence=0.95: "midterm季焦虑到睡不着大家会去student wellness吗"
- `cs_271` / health_wellness: q=0.543429, y=1, confidence=0.94: "没有family doctor的学生平时看病都怎么解决"
- `cs_276` / health_wellness: q=0.521267, y=1, confidence=0.76: "没有family doctor的学生一般去哪看病"

## Nearest boundary cases

- `cs_042` / campus_event: q=0.554737, y=1, confidence=0.95: "你们大学开学welcome week值得每场都去吗"
- `cs_044` / campus_event: q=0.555414, y=1, confidence=0.92: "加拿大大学社团招新一般九月之后还来得及加入吗"
- `cs_270` / health_wellness: q=0.543612, y=1, confidence=0.95: "midterm季焦虑到睡不着大家会去student wellness吗"
- `cs_271` / health_wellness: q=0.543429, y=1, confidence=0.94: "没有family doctor的学生平时看病都怎么解决"
- `cs_047` / campus_event: q=0.539378, y=1, confidence=0.67: "club fair到底能不能认识到人啊"
- `cs_119` / academics_general: q=0.563051, y=1, confidence=0.72: "挂一门课对grad school影响真有那么大吗"
- `cs_275` / health_wellness: q=0.574248, y=1, confidence=0.73: "大学counselling是不是通常都排很久"
- `cs_048` / campus_event: q=0.522670, y=1, confidence=0.75: "开学活动一个人去正常吗"
- `cs_276` / health_wellness: q=0.521267, y=1, confidence=0.76: "没有family doctor的学生一般去哪看病"
- `cs_269` / health_wellness: q=0.587108, y=1, confidence=0.97: "大学counselling centre排队很久是不是普遍问题"
- `cs_115` / academics_general: q=0.592144, y=1, confidence=0.94: "加拿大大学deferred exam流程是不是都特别慢"
- `cs_043` / campus_event: q=0.600241, y=1, confidence=0.94: "校园活动一个人去会不会很尴尬，大家都是怎么认识人的"
- `cs_041` / campus_event: q=0.601729, y=1, confidence=0.97: "大家学校club fair真的能交到朋友吗还是拿一堆传单就走"
- `cs_114` / academics_general: q=0.602382, y=1, confidence=0.95: "大家高年级还会经常因为选课焦虑吗"
- `cs_113` / academics_general: q=0.604316, y=1, confidence=0.97: "大学第一次挂科之后真的会影响研究生申请很多吗"
- `cs_267` / health_wellness: q=0.487659, y=0, confidence=0.95: "campus clinic验血需要先找family doctor referral吗"
- `cs_266` / health_wellness: q=0.485203, y=0, confidence=0.96: "学校counselling预约现在要等几周"
- `cs_274` / health_wellness: q=0.481521, y=0, confidence=0.74: "学校counselling现在要等多久"
- `cs_116` / academics_general: q=0.620846, y=1, confidence=0.92: "本科GPA到底从什么时候开始比课程难度更重要"
- `cs_120` / academics_general: q=0.621225, y=1, confidence=0.7: "高年级选课焦虑是不是很正常"

## Scenario correlations

| Scenario | N | FP | FN |
| --- | ---: | ---: | ---: |
| academics_general | 12 | 0 | 0 |
| campus_event | 12 | 0 | 2 |
| health_wellness | 12 | 0 | 3 |

## Human interpretation required

Review campus proper nouns, slang, short posts, code switching, course codes, housing, coop, and vague pronouns/context. Scenario counts are associations, not causal evidence. Mark each false positive/negative with these attributes; compare matched counterfactual wording before concluding semantic transferability versus lexical shortcuts. No automated claim of semantic understanding is made.
