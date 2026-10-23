import Foundation

/// Original-language literary excerpts, rather than translations of one sample.
struct LiteraryFontSample {
    let text: String
    let author: String
    let work: String
    let sourceURL: String
    var attribution: String { "\(author) · \(work)" }
}

enum ReaderFontSamples {
    static func sample(for language: ReaderLanguage) -> LiteraryFontSample {
        switch language.resolved() {
        case .zhHans:
            return .init(text: "滚滚长江东逝水", author: "杨慎", work: "临江仙",
                         sourceURL: "https://zh.wikisource.org/wiki/臨江仙_(楊慎)")
        case .zhHant:
            return .init(text: "滾滾長江東逝水", author: "楊慎", work: "臨江仙",
                         sourceURL: "https://zh.wikisource.org/wiki/臨江仙_(楊慎)")
        case .en, .system:
            return .init(text: "To be, or not to be, that is the question", author: "William Shakespeare", work: "Hamlet · Act III, Scene I",
                         sourceURL: "https://www.gutenberg.org/files/1524/1524-h/1524-h.htm")
        case .ja:
            return .init(text: "私を焼き亡ぼす火は金閣をも焼き亡ぼすだろう", author: "三島由紀夫", work: "金閣寺 · 第二章",
                         sourceURL: "https://silvajp.web.amu.edu.pl/wp-content/uploads/2021/08/Silva-5051.pdf#page=19")
        case .ko:
            return .init(text: "죽는 날까지 하늘을 우러러\n한 점 부끄럼이 없기를", author: "윤동주", work: "서시",
                         sourceURL: "https://news.yonsei.ac.kr/kr/news/detail?bbSeq=35027")
        case .fr:
            return .init(text: "Le cœur a ses raisons que la raison ne connaît point", author: "Blaise Pascal", work: "Pensées",
                         sourceURL: "https://www.penseesdepascal.fr/XXIII/XXIII3-approfondir.php")
        case .de:
            return .init(text: "Zwei Seelen wohnen, ach! in meiner Brust", author: "Johann Wolfgang von Goethe", work: "Faust I · Vor dem Tor",
                         sourceURL: "https://projekt-gutenberg.org/authors/johann-wolfgang-von-goethe/books/faust-eine-tragoedie/chapter/6/")
        case .es:
            return .init(text: "La libertad, Sancho, es uno de los más preciosos dones que a los hombres dieron los cielos", author: "Miguel de Cervantes", work: "Don Quijote de la Mancha · II, 58",
                         sourceURL: "https://cvc.cervantes.es/actcult/quijote_carlos/presentacion.htm")
        case .pt:
            return .init(text: "Tudo vale a pena\nSe a alma não é pequena.", author: "Fernando Pessoa", work: "Mar Português · Mensagem",
                         sourceURL: "https://pt.wikisource.org/wiki/Mar_Portuguez")
        }
    }
}
