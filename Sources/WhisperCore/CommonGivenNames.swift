import Foundation

/// Common first names, for one decision only: whether a Correct Toward Vocabulary row would turn one
/// person's name into another's (F1064). Spelling cannot tell Carla from a mishearing of Carl, or
/// Sarah from Sara, so a row whose changed words are all such names arrives unticked — the user's
/// decision of 2026-10-22 ("Start unticked"). A row toward a name from a word that is not one (a
/// mishearing) is unaffected.
///
/// Compiled for this check from the first names most often given in English-speaking countries, with
/// common Spanish, Portuguese, French, German, Italian, Indian, Arabic and Hebrew names, and spelling
/// variants in common use. Not a register of names and not complete: a name missing here leaves its
/// row ticked, as every row was before. Lowercased; compared lowercased.
public enum CommonGivenNames {
    public static func contains(_ word: String) -> Bool { names.contains(word.lowercased()) }

    static let names: Set<String> = Set("""
    aaron abby abigail abraham ada adam addison adrian adriana adrienne agnes ahmed aidan aiden aisha
    alan alana albert alberto alejandra alejandro alex alexa alexander alexandra alexandria alexis alfred
    ali alice alicia alina alison alissa allan allen allison alma alvin amanda amber amelia amir amit amy
    ana anastasia andre andrea andres andrew andy angel angela angelica angelina angie anita ann anna
    annabelle anne annette annie anthony antonio anya april arjun arnold arthur arturo asha ashley
    ashton aubrey audrey austin ava avery barbara barry beatrice becky belinda ben benjamin bernard
    beth bethany betty beverly bianca bill billy blake bob bobby bonnie brad bradley brandon brandy
    brenda brendan brent brett brian briana brianna bridget brittany brooke bruce bryan bryce caleb
    calvin cameron camila camille candace cara carl carla carlos carmen carol carole caroline carolyn
    carrie carson casey cassandra catherine cathy cecilia cedric celia chad charlene charles charlie
    charlotte chase chelsea cheryl chloe chris christian christina christine christopher christy cindy
    claire clara clarence claudia clay clayton clifford clint colin colleen connor conrad constance cora
    corey courtney craig cristina crystal curtis cynthia daisy dale damian dan dana daniel daniela
    danielle danny darius darlene darren dave david dawn dean debbie deborah debra deepak denise dennis
    derek desmond devin diana diane diego dimitri dina dolores dominic don donald donna dora doris
    dorothy doug douglas drew duncan dustin dylan eddie edgar edith eduardo edward edwin eileen elaine
    eleanor elena eli elias elijah elisa elise eliza elizabeth ella ellen ellie elliot elliott eloise
    elsa emil emilia emily emma emmanuel enrique eric erica erik erika erin ernest esther ethan eugene
    eva evan evelyn faith farah fatima felicia felix fernando fiona frances francesca francis francisco
    frank franklin fred freddie frederick gabriel gabriela gabrielle gail gary gavin gene george georgia
    gerald geraldine gina giovanni giselle giuseppe gloria gordon grace graham grant greg gregory greta
    gustavo guy hailey haley hamza hana hank hannah harold harper harriet harrison harry harvey hassan
    hazel heather hector heidi helen helena henry herbert holly hope howard hugh hugo hunter ian ibrahim
    ida imani imran irene iris isaac isabel isabella isabelle ivan ivy jack jackie jackson jacob jacqueline
    jada jade jaime jake james jamie jan jana jane janet janice jared jasmine jason javier jay jean jeanette
    jeanne jeff jeffrey jenna jennifer jenny jeremy jerome jerry jess jesse jessica jesus jill jim jimmy
    jo joan joann joanna joanne jody joe joel johanna john johnny jon jonah jonathan jordan jorge jose
    joseph josephine josh joshua joy joyce juan juanita judith judy julia julian juliana julie juliet
    june justin kai kara karen kari karina karl kate katelyn katherine kathleen kathryn kathy katie katrina
    kay kayla keith kelly kelsey ken kendra kenneth kenny kent kerry kevin khalid kim kimberly kirk kristen
    kristin kristina krystal kurt kyle lana lance landon lara larry laura lauren laurie lawrence leah lee
    leila lena leo leon leonard leonardo leslie lewis liam lila lillian lily linda lindsay lindsey lisa
    liz logan lois lola lora lorena lorenzo loretta lori lorraine louis louise lucas lucia lucy luis luke
    luna lydia lynn mabel mackenzie madeline madison maggie malcolm mandy manuel marc marcia marco marcus
    margaret maria mariah marian marie marilyn marina mario marion marisa marissa mark marlene marsha
    martha martin marvin mary mason mateo mathew matt matthew maureen maurice max maxine maya megan meghan
    melanie melissa melody meredith mia micah michael michaela michelle miguel mike mila miles milo
    mindy miranda miriam mohamed mohammed molly monica morgan muhammad mya nadia nancy naomi natalie
    natasha nathan nathaniel neha neil nell nelson nia nicholas nick nicole nina noah noel nora norma
    norman oliver olivia omar oscar owen pablo paige pam pamela paris pat patricia patrick paul paula
    pauline pedro peggy penelope penny pete peter philip phillip phoebe phyllis pierre piper polly
    pooja preston priscilla priya quentin quinn rachel rafael rahul raj rajesh ralph ramon randall randy
    raquel raul ray raymond rebecca regina reid rena renee rhonda ricardo richard rick ricky riley rita rob
    robert roberta roberto robin rocco rodney roger roland ron ronald ronnie rosa rosalind rose rosemary
    ross roxanne roy ruby rudy russell ruth ryan sabrina sadie sally salma sam samantha samir samuel sandra
    sandy sanjay santiago sara sarah sasha saul savannah scott sean selena sergio seth shane shannon sharon
    shawn sheila shelby shelly sherry shirley sidney simon simone sofia sonia sophia sophie stacey stacy
    stanley stella stephanie stephen steve steven stuart sue sunil susan suzanne sydney sylvia tamara tammy
    tanya tara taylor ted teresa terrence terri terry tessa theodore theresa thomas tiffany tim timothy
    tina toby todd tom tommy toni tony tracy travis trevor tricia trinity troy tyler valentina valerie
    vanessa vera veronica vicki vicky victor victoria vijay vikram vincent violet virginia vivian wade
    walter wanda warren wayne wendy wesley whitney will william willie wilson xavier yasmin yolanda
    yusuf yvette yvonne zach zachary zara zoe
    """.split(whereSeparator: \.isWhitespace).map(String.init))
}
