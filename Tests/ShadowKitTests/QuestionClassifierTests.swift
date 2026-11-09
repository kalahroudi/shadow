import XCTest
@testable import ShadowKit

/// R11 / A11: ten or more questions and non-questions per language.
final class QuestionClassifierTests: XCTestCase {
    private func check(_ questions: [String], _ statements: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(questions.count, 10, file: file, line: line)
        XCTAssertGreaterThanOrEqual(statements.count, 10, file: file, line: line)
        for q in questions { XCTAssertNotNil(QuestionClassifier.classify(q).text, "should be a question: \(q)", file: file, line: line) }
        for s in statements { XCTAssertEqual(QuestionClassifier.classify(s), .notQuestion, "should not be a question: \(s)", file: file, line: line) }
    }

    func testEnglish() {
        check(["What is your biggest weakness?", "Why do you want this job", "How would you design a rate limiter",
               "Can you walk me through your resume", "Tell me about a time you failed.", "Could you explain how hashing works",
               "Do you have experience with Kubernetes?", "Where do you see yourself in five years", "Are you comfortable with on-call",
               "Describe your leadership style.", "Walk me through the architecture", "Who owns the roadmap?", "Is there a budget for this",
               "So, um, what did you build there"],
              ["I think that went well.", "We shipped the feature last week.", "Thanks for joining us today.", "That's a great point.",
               "I worked at Acme for three years.", "Have a great day.", "The meeting starts at ten.", "What I mean is we are late.",
               "Let me share my screen.", "He said it was fine.", "Great, let's get started.", "How I got here is a long story."])
    }

    func testSpanish() {
        check(["¿Cuál es tu mayor debilidad?", "¿Puedes explicarme tu experiencia", "Cuéntame sobre tu último proyecto", "¿Por qué quieres este trabajo",
               "Cómo diseñarías un sistema de colas", "Dime qué opinas del plan", "¿Qué opinas?", "Podrías describir tu rol actual",
               "¿Dónde te ves en cinco años?", "Explícame cómo funciona el caché", "¿Tienes experiencia con Python?", "Cuántos años de experiencia tienes"],
              ["Me gusta mucho este equipo.", "Ayer terminamos el informe.", "Gracias por venir hoy.", "Trabajé tres años en esa empresa.",
               "Creo que salió bien.", "La reunión empieza a las diez.", "Ella lidera el proyecto desde enero.", "Vamos a empezar ahora.",
               "Eso es un buen punto.", "Mañana tengo otra entrevista.", "Nos vemos pronto.", "Hola a todos."])
    }

    func testGerman() {
        check(["Was ist Ihre größte Schwäche?", "Warum möchten Sie diese Stelle", "Wie würden Sie ein Rate-Limit entwerfen", "Können Sie Ihren Lebenslauf erklären",
               "Erzähl mir von deinem letzten Projekt", "Hast du Erfahrung mit Kubernetes", "Wo sehen Sie sich in fünf Jahren", "Beschreibe deinen Führungsstil",
               "Kannst du das kurz erklären?", "Welche Sprachen sprechen Sie", "Wer verantwortet die Roadmap?", "Gibt es dafür ein Budget",
               "Sag mir, was du davon hältst"],
              ["Ich finde, das lief gut.", "Wir haben das Feature letzte Woche veröffentlicht.", "Danke, dass Sie da sind.", "Das ist ein guter Punkt.",
               "Ich habe drei Jahre bei Acme gearbeitet.", "Das Meeting beginnt um zehn.", "Wie gesagt, wir sind spät dran.", "Was ich meine, ist dass wir spät sind.",
               "Er hat gesagt, es sei in Ordnung.", "Fangen wir an.", "Gestern habe ich den Bericht beendet.", "Guten Morgen zusammen."])
    }

    func testFrench() {
        check(["Quelle est votre plus grande faiblesse ?", "Pourquoi voulez-vous ce poste", "Comment concevriez-vous un limiteur de débit",
               "Pouvez-vous expliquer votre parcours", "Parlez-moi de votre dernier projet", "Avez-vous de l'expérience avec Kubernetes",
               "Où vous voyez-vous dans cinq ans", "Décrivez votre style de gestion.", "Est-ce que tu peux expliquer ça ?", "Dis-moi ce que tu en penses",
               "Qui dirige la feuille de route ?", "Combien d'années d'expérience avez-vous", "Peux-tu m'aider"],
              ["Je pense que ça s'est bien passé.", "Nous avons livré la fonctionnalité la semaine dernière.", "Merci d'être venus aujourd'hui.",
               "C'est un bon point.", "J'ai travaillé trois ans chez Acme.", "La réunion commence à dix heures.", "Quand je suis arrivé, tout était calme.",
               "Il a dit que c'était bon.", "Commençons maintenant.", "Hier, j'ai terminé le rapport.", "Bonjour à tous.", "Nous verrons demain."])
    }

    func testJapanese() {
        check(["あなたの一番の弱みは何ですか？", "なぜこの仕事を選んだのですか", "これまでの経験を教えてください", "最近のプロジェクトについて話してください。",
               "Kubernetesの経験はありますか", "5年後はどうなっていたいですか。", "チームをどうまとめますか?", "システムの設計を説明して",
               "どのように問題を解決しましたか", "予算はありますか", "詳しくお願いします", "これで合っていますか"],
              ["今日はありがとうございます。", "先週、機能をリリースしました。", "私はアクメで三年間働きました。", "それは良い指摘ですね。",
               "会議は十時に始まります。", "うまくいったと思います。", "では始めましょう。", "昨日レポートを書き終えました。", "なぜなら時間がなかったからです。",
               "おはようございます。", "彼は大丈夫だと言いました。", "明日また連絡します。"])
    }

    func testOnlyTheFinalSentenceDecides() {
        XCTAssertEqual(QuestionClassifier.classify("Thanks for that. What is your experience with Swift?"), .question("What is your experience with Swift?"))
        XCTAssertEqual(QuestionClassifier.classify("What is your experience with Swift? Okay, moving on."), .notQuestion)
    }

    func testEmptyAndPunctuationOnlyAreNotQuestions() {
        XCTAssertEqual(QuestionClassifier.classify(""), .notQuestion)
        XCTAssertEqual(QuestionClassifier.classify("   "), .notQuestion)
        XCTAssertEqual(QuestionClassifier.classify("..."), .notQuestion)
    }

    func testDecimalPointDoesNotEndASentence() {
        XCTAssertNotNil(QuestionClassifier.classify("What do you think about version 3.5").text)
        XCTAssertEqual(QuestionClassifier.classify("What do you think about version 3.5").text, "What do you think about version 3.5")
    }

    func testFrenchOnQuestionsAndJapanesePastTenseOrGreeting() {
        XCTAssertNotNil(QuestionClassifier.classify("Comment on fait ça").text)
        for s in ["よろしくお願いします。", "詳しく説明しました。", "先生が教えてくれました。"] {
            XCTAssertEqual(QuestionClassifier.classify(s), .notQuestion, s)
        }
        XCTAssertNotNil(QuestionClassifier.classify("詳しく教えてください").text)
    }
}
