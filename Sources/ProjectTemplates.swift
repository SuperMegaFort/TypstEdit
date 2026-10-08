import Foundation

struct ProjectTemplate: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let description: String
    let icon: String // SF Symbol name
    let content: String
}

class ProjectTemplates {
    static let all: [ProjectTemplate] = [
        ProjectTemplate(
            name: L10n.text("Chinese / English", "中英文文档"),
            description: L10n.text("Chinese fonts and bilingual text.", "中文字体与中英混排示例。"),
            icon: "character.book.closed",
            content: """
            #set page(paper: "a4", margin: 2cm)
            #set text(font: ("New Computer Modern", "PingFang SC"), lang: "zh", size: 11pt)
            #set par(justify: true)

            = 中英文文档 / Bilingual Document

            中文输入与 English 可以混排。数学公式：$ E = m c^2 $。

            == 开始写作 / Getting started

            在此输入正文。Write your text here.
            """
        ),
        ProjectTemplate(
            name: L10n.text("Empty Project", "空白项目"),
            description: L10n.text("A blank canvas for your document.", "从空白文档开始。"),
            icon: "doc.text",
            content: """
            #set page(width: auto, height: auto, margin: 1cm)
            
            = New Document
            
            Start typing here...
            """
        ),
        ProjectTemplate(
            name: L10n.text("Article", "文章"),
            description: L10n.text("A standard article format with title and sections.", "包含标题和章节的标准文章。"),
            icon: "doc.text.fill",
            content: """
            #set page(
              paper: "a4",
              margin: (x: 2cm, y: 2.5cm),
            )
            #set text(
              font: ("New Computer Modern", "PingFang SC"),
              size: 11pt,
            )
            
            = Article Title
            
            == Introduction
            
            This is the introduction to your article.
            
            == Content
            
            Your content goes here.
            """
        ),
        ProjectTemplate(
            name: L10n.text("Report", "报告"),
            description: L10n.text("A detailed report with table of contents.", "包含目录的详细报告。"),
            icon: "book.closed.fill",
            content: """
            #set page(paper: "a4", numbering: "1")
            
            #align(center + horizon)[
              #text(size: 24pt, weight: "bold")[Report Title]
              
              #v(2em)
              
              Author Name
              
              #datetime.today().display()
            ]
            
            #pagebreak()
            
            #outline(indent: auto)
            
            #pagebreak()
            
            = Executive Summary
            
            Write your summary here.
            
            = Introduction
            
            Introduction content.
            """
        ),
        ProjectTemplate(
            name: L10n.text("Presentation", "演示文稿"),
            description: L10n.text("Slides for a presentation.", "用于演讲的幻灯片。"),
            icon: "rectangle.inset.filled.on.rectangle",
            content: """
            #set page(
              paper: "presentation-16-9",
              margin: 2cm,
            )
            #set text(size: 20pt)
            
            #align(center + horizon)[
              = Presentation Title
              
              Presenter Name
            ]
            
            #pagebreak()
            
            == Slide 1
            
            - Point 1
            - Point 2
            
            #pagebreak()
            
            == Slide 2
            
            Content for slide 2.
            """
        ),
        ProjectTemplate(
            name: L10n.text("Resume", "简历"),
            description: L10n.text("A clean and professional resume layout.", "简洁专业的简历排版。"),
            icon: "person.text.rectangle",
            content: """
            #set page(paper: "a4", margin: 1.5cm)
            #set text(font: ("New Computer Modern", "PingFang SC"), size: 10pt)
            
            #align(center)[
              #text(size: 14pt, weight: "bold")[Your Name]
              
              email@example.com | +123 456 7890 | city, country
            ]
            
            = Experience
            
            == Job Title
            *Company Name* | 2020 - Present
            
            - Achievement 1
            - Achievement 2
            
            = Education
            
            == Degree Name
            *University Name* | 2016 - 2020
            """
        )
    ]
}
